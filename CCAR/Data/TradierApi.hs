module CCAR.Data.TradierApi 
    (startup, query, QueryOptionChain, queryMarketData, TradierMarketDataServer(..))
where 

import CCAR.Main.DBOperations (Query, query, manage, Manager)
import Network.HTTP.Conduit 

import Data.Set as Set 
import Data.Map as Map
-- The streaming interface
import           Control.Monad.IO.Class  (liftIO)
import           Data.Aeson              (Value (Object, String, Array) 
                                          , toJSON 
                                          , fromJSON)
import           Data.Aeson              (encode, object, (.=), (.:), decode
                                            , parseJSON)
import           Data.Aeson.Parser       (json)
import           Data.Aeson.Types        (parse, ToJSON, FromJSON, toJSON)
import           Data.Conduit            (($$+-))
import           Data.Conduit.Attoparsec (sinkParser)
import           Network.HTTP.Conduit    (RequestBody (RequestBodyLBS),
                                          Response (..), http, method, parseUrl,
                                          requestBody, withManager)
import          CCAR.Parser.CSVParser as CSVParser(parseCSV, ParseError, parseLine)
import          Control.Concurrent(threadDelay)
import          Data.Text as T 
import          Data.Text.Lazy as L
import          Data.ByteString.Lazy as LB 
import          Data.Text.Lazy.Encoding as LTE
import          Data.Aeson.Types     as AeTypes(Result(..), parse)
import          Data.ByteString.Internal     as S
import          Data.HashMap.Strict          as M 
import          Control.Exception hiding(Handler)

import          Database.Persist
import          Database.Persist.TH 

import          qualified CCAR.Main.GroupCommunication as GC
import          Database.Persist.Postgresql as DB
import          Data.Time
import          Data.Time.Calendar.OrdinalDate (sundayStartWeek)
import          Data.Map
import          System.Locale(defaultTimeLocale)
import          System.Environment(getEnv)
import          Control.Monad.IO.Class 
import          Control.Monad
import          Control.Monad.Logger 
import          Control.Monad.Trans(lift)
import          Control.Monad.Trans.Maybe
import          Control.Monad.Trans.Resource
import          Control.Applicative as Appl
import          Control.Monad.Trans.Resource
import          Control.Monad.Trans.Maybe(runMaybeT)
import          Control.Monad.Trans(lift)
import          Data.Monoid(mappend, (<>))
import          CCAR.Main.DBUtils
import          CCAR.Command.ApplicationError(appError)
import          System.Environment(getEnv)
import          GHC.Generics
import          GHC.IO.Exception
import          Data.Vector
import          Data.Scientific
import          Data.Data
import          Data.Monoid (mappend)
import          Data.Typeable 
import          System.Log.Logger as Logger
import          Data.Conduit.Binary as B (sinkFile, lines, sourceFile) 
import          Data.Conduit.List as CL 
import          Data.ByteString.Char8 as BS(ByteString, pack, unpack) 
import          Data.Conduit ( ($$), (=$=), (=$), Conduit, await, yield)
import          CCAR.Data.MarketDataAPI as MarketDataAPI
import          CCAR.Model.PortfolioT as PortfolioT
import          CCAR.Model.Portfolio as Portfolio
import          CCAR.Model.PortfolioSymbol as PortfolioSymbol hiding (symbol)
import          CCAR.Main.Util as Util hiding (parse_float)
import          Network.WebSockets.Connection as WSConn
import          CCAR.Model.CcarDataTypes
import          CCAR.Main.Application
import          Control.Concurrent.STM.Lifted
import          CCAR.Analytics.MarketDataLanguage
import          CCAR.Data.ClientState
import          CCAR.Main.OptionUtils

iModuleName = "CCAR.Data.TradierApi"
baseUrl =  "https://sandbox.tradier.com/v1"

quotesUrl =  "markets/quotes"
timeAndSales = "markets/timesales"
optionChains = "markets/options/chains"
provider = "Tradier"

historicalMarketData = "markets/history"

insertTradierProvider = 
    (dbOps $ do
        get <- DB.getBy $ UniqueProvider provider 
        liftIO $ Logger.debugM iModuleName $ "Inserting tradier provider " `mappend` (show get)
        y <- case get of 
                Nothing ->do 
                    x <- DB.insert $ MarketDataProvider 
                            provider baseUrl "" timeAndSales optionChains
                    return $ Right x
                Just x -> return $ Left $ "Record exists. Not inserting" 

        liftIO $ Logger.debugM iModuleName $ "Inserted provider " `mappend` (show y)
    ) `catch` (\x@(SomeException s) -> do
        Logger.errorM iModuleName $ "Error inserting tradier" `mappend`  (show x))
getMarketData :: LB.ByteString -> [(BS.ByteString, Maybe BS.ByteString)] -> IO Value
getMarketData url queryString =  handle (\e@(FailedConnectionException2 a b c d) -> 
                return $ String "Connection exception") $ do 
        liftIO $ Logger.debugM iModuleName $ "Query market data " <> (show queryString)
        authBearerToken <- getEnv("TRADIER_BEARER_TOKEN") >>= 
            \x ->  return $ S.packChars $ "Bearer " `mappend` x
        (\x@(SomeException e) -> do
                    liftIO $ Logger.debugM iModuleName $ 
                            ("Error " <> (show x))
                    return $ String $ "Error " <> (T.pack . show $ x)
            ) 
            `handle` (runResourceT $ do 
                manager <- liftIO $ newManager tlsManagerSettings 

                req <- liftIO $ parseUrl makeUrl
                req <- return $ req {requestHeaders = 
                        [("Accept", "application/json") 
                        , ("Authorization", 
                            authBearerToken)]
                        }
                req <- return $ setQueryString queryString req 
                res <- http req manager 
                value <- responseBody res $$+- sinkParser json 
                return value) 
        where 
            makeUrl = S.unpackChars $ LB.toStrict $ LB.intercalate "/" [baseUrl, url]


getQuotes = \x  -> getMarketData quotesUrl [("symbols", Just x)] 

getTimeAndSales y = \x -> getMarketData timeAndSales [("symbol", Just x)]


getHistoricalData = \x -> do 

    mData <- getMarketData historicalMarketData [("symbol", Just x)] 
    case mData of 
        Object value -> do 
            history <- return $ M.lookup "history" value
            case history of 
                Just (Object aValue) -> do
                    day <- return $ M.lookup "day" aValue 
                    case day of 
                        Just aValue2 -> do 
                            case aValue2 of 
                                a@(Array x2) -> return $ Right $ fmap (\y -> fromJSON y :: Result MarketDataTradier) x2
                                _           -> return $ Left $ "Error processing " `mappend` (show aValue2)
                _   -> return $ Left $ "Error processing " <> show x
        _           -> return $ Left $ "Error processing " <> (show x)


getOptionChains = \x y -> do 
    liftIO $ Logger.debugM iModuleName ("Inside option chains " `mappend` (show x) `mappend` (show y))
    oData <- getMarketData optionChains [("symbol", Just x), ("expiration", Just y )]
    case oData of 
        Object value -> do 
                liftIO $ Logger.debugM iModuleName ("getOptionChains " `mappend` (show value))
                options <- return $ M.lookup "options" value 
                liftIO $ Logger.debugM iModuleName (show options)
                case options of 
                    Just (Object object) -> do 
                        object <- return $ M.lookup "option" object
                        case object of 
                            Just aValue -> do
                                case aValue of 
                                    a@(Array x) ->  do  
                                        return $ Right $ fmap (\y -> fromJSON y :: Result OptionChainMarketData) x 
                                    _ -> return $ Left $ "Error processing" `mappend` (show y)
                            _ -> return $ Left $ "Error processing " `mappend` (show y)
                    _ -> return $ Left "Nothing to process"
        _       -> return $ Left "Nothing to process. Market Data error"
        


insertOptionChain x = dbOps $ do 
    liftIO $ Logger.debugM iModuleName ("inserting single " `mappend` (show x))
    x <- runMaybeT $ do 
        Just (Entity kId providerEntity) <- 
                lift $ DB.getBy $ UniqueProvider provider
        liftIO $ Logger.debugM iModuleName $ "Entity  " `mappend` (show providerEntity)
        lift $ DB.insert $ OptionChain  
            (symbol x)
            (underlying x)
            (T.pack $ show $ strike x)
            (expiration x)              
            (optionType x)
            (T.pack $ show $ lastPrice x)
            (T.pack $ show $ bidPrice x) 
            (T.pack $ show $ askPrice x)
            (T.pack $ show $ change x)
            (T.pack $ show $ openInterest x)
            (kId)
    return x    

--insertHistoricalPrice :: MarketDataTradier -> T.Text -> 
insertHistoricalPrice y@(MarketDataTradier date open close high low volume) symb= dbOps $ do 
    liftIO $ Logger.debugM iModuleName $ "Inserting " `mappend` (show y)
    now <- liftIO $ getCurrentTime
    runMaybeT $ do 
        Just utcdate <- return $ parseTime defaultTimeLocale "%F" (T.unpack date)
        Just (Entity kid providerEntity) <- 
            lift $ DB.getBy $ UniqueProvider provider
        Nothing <- lift $ DB.getBy $ MarketDataIdentifier symb utcdate 
        lift $ DB.insert $ HistoricalPrice symb 
                        utcdate 
                        open 
                        close 
                        high 
                        low 
                        volume
                        now 
                        kid

    
data PortfolioStressValue = PortfolioStressValue {
        psNickName :: T.Text
        , psCommandType :: T.Text
        , psTime :: UTCTime 
        , portfolioSymbol :: PortfolioSymbolT  
        , psValue :: Double     
    } deriving (Show, Eq)

instance ToJSON PortfolioStressValue where 
    toJSON (PortfolioStressValue n c t ps psV) = object [
            "nickName" .= n 
            , "commandType" .= c 
            , "date" .= t 
            , "portfolioSymbol" .= ps 
            , "portfolioValue" .= psV
        ]

instance FromJSON PortfolioStressValue where 
    parseJSON (Object v) = PortfolioStressValue <$> 
                    v .: "nickName"  <*> 
                    v .: "commandType" <*> 
                    v .: "date" <*> 
                    v .: "portfolioSymbol" <*> 
                    v .: "portfolioValue"
    parseJSON _     = Appl.empty
makePortfolioStressValue = PortfolioStressValue 

data BidRatio = BidRatio Float Float deriving (Show, Eq, Generic)
instance ToJSON BidRatio
instance FromJSON BidRatio 

data QueryOptionChain = QueryOptionChain {
    qNickName :: T.Text
    , qCommandType :: T.Text
    , qUnderlying :: T.Text
    , optionChain :: ![OptionChain] 
} deriving (Eq)

instance Show QueryOptionChain where 
    show (QueryOptionChain a b c d) = 
        show a <> ":" <> show b <> ":" <> show c <> ":" <> 
                    show (Prelude.take 10 d) <> "..." <> (show $ Prelude.length $ d)

parseQueryOptionChain v = QueryOptionChain <$> 
                v .: "nickName" <*>
                v .: "commandType" <*> 
                v .: "underlying" <*> 
                v .: "optionChain"

genQueryOptionChain (QueryOptionChain n c underlying res) = 
        object [
            "nickName" .= n 
            , "commandType" .= c 
            , "underlying" .= underlying 
            , "optionChain" .= res 

        ]


instance ToJSON QueryOptionChain where 
    toJSON = genQueryOptionChain 

instance FromJSON QueryOptionChain where
    parseJSON (Object v) = parseQueryOptionChain v 
    parseJSON _          = Appl.empty



instance Query QueryOptionChain where 
    query = queryOptionChain

data OptionChainMarketData = OptionChainMarketData {
        symbol :: T.Text 
        , underlying :: T.Text 
        , strike :: Scientific
        , expiration :: T.Text
        , optionType :: T.Text
        , lastPrice :: Maybe Scientific
        , bidPrice :: Maybe Scientific
        , askPrice :: Maybe Scientific
        , change :: Maybe Scientific
        , openInterest :: Maybe Scientific
    }deriving (Show, Eq, Data, Generic, Typeable)


instance FromJSON OptionChainMarketData where 
    parseJSON (Object o) = OptionChainMarketData <$> 
                                o .: "symbol" <*>
                                o .: "underlying" <*> 
                                o .: "strike" <*>
                                o .: "expiration_date" <*> 
                                o .: "option_type" <*>
                                o .: "last" <*> 
                                o .: "bid" <*> 
                                o .: "ask" <*> 
                                o .: "change" <*> 
                                o .: "open_interest"
    parseJSON _          = Appl.empty
instance ToJSON OptionChainMarketData

{-            symbol Text
            date UTCTime default=CURRENT_TIMESTAMP
            open Text default="0.0"
            close Text default="0.0"
            high Text default="0.0"
            low Text default="0.0"
            volume Text default="0.0"
            lastUpdateTime UTCTime default=CURRENT_TIMESTAMP
            dataProvider MarketDataProviderId 
            MarketDataIdentifier symbol date
-}                      

data MarketDataTradier = MarketDataTradier {
    date :: T.Text 
    , open :: Double
    , close :: Double
    , high :: Double
    , low :: Double
    , volume :: Double
} deriving(Show, Eq, Ord)
instance ToJSON MarketDataTradier where 
    toJSON (MarketDataTradier date open close high low volume)  = 
        object [
            "date" .= date 
            , "open" .= open
            , "close" .= close 
            , "high" .= high 
            , "low" .= low 
            , "volume" .= volume 
        ]

instance FromJSON MarketDataTradier where 
    parseJSON (Object o) =  do 
            date <- o .: "date" 
            open <- o .: "open" 
            close <- o .:  "close" 
            high <- o .: "high" 
            low <-  o  .: "low"
            volume <- o .: "volume"
            return $ MarketDataTradier 
                        date 
                        open
                        close 
                        high
                        low 
                        volume

    parseJSON  _ = Appl.empty

{-- | Returns the option expiration date for n months from now. 
 Complicated logic alert: 
  * Get the number of days left in the current month.
  * Get all the options for the last friday of the month.
  * This can probably be better replaced by getting 
  the market calendar from the market.

--}


defaultExpirationDate = Util.lastFridayOfMonth 0



insertDummyMarketData = dbOps $ do
    time <- liftIO $ getCurrentTime 
    y <- runMaybeT $ do 
        x <- lift $ selectList [][Asc EquitySymbolSymbol]
        Just (Entity kid providerEntity) <- 
                lift $ DB.getBy $ UniqueProvider provider
        y <- Control.Monad.mapM (\a @(Entity k val) -> do 
                lift $ DB.insert $ HistoricalPrice (equitySymbolSymbol val) 
                                    (time)
                                    1.0
                                    1.0
                                    1.0
                                    1.0
                                    1.0
                                    time 
                                    kid                 
                newTime <- liftIO $ return $ addUTCTime (24 * 3600) time
                lift $ DB.insert $ HistoricalPrice (equitySymbolSymbol val) 
                                    (newTime)
                                    3.0
                                    3.0
                                    3.0
                                    3.0
                                    3.0
                                    time
                                    kid                 
                                    ) x 

        return () 
    return y




--TODO: Exception handling needs to be robust.
insertAndSave :: [String] -> IO (Either T.Text T.Text)
insertAndSave x = (dbOps $ do
    symbol <- return $ T.pack $ x !! 0 
    symbolExists <- getBy $ UniqueEquitySymbol symbol 
    case symbolExists of 
        Nothing ->  do
                i <- DB.insert $ EquitySymbol symbol
                            (T.pack $ x !! 1)
                            (T.pack $ x !! 2) 
                            (T.pack $ x !! 3)
                            (T.pack $ x !! 4)
                            (read (x !! 5) :: Int )
                liftIO $ Logger.debugM iModuleName ("Insert succeeded " `mappend` (show i))
                return $ Right symbol
        Just x -> return $ Right symbol 
                )
                `catch`
                (\y -> do 
                        Logger.errorM iModuleName $ 
                            "Failed to insert " `mappend` (show (y :: SomeException))
                        return $ Left "ERROR")

    
parseSymbol :: (Monad m, MonadIO m) => Conduit BS.ByteString m (Either ParseError [String])
parseSymbol = do 
    client <- await 
    case client of 
        Nothing -> return () 
        Just aBS -> do 
                yield $ CSVParser.parseLine $ BS.unpack aBS
                parseSymbol


saveSymbol :: (MonadIO m) => Conduit (Either ParseError [String]) m (Either T.Text T.Text)
saveSymbol = do 
    client <- await 
    case client of 
        Nothing -> return () 
        Just oString -> do 
            case oString of                 
                Right x -> do 
                    x <- liftIO $ insertAndSave x                                       
                    yield x 
                    return x
            
            saveSymbol

-- | Returns the symbol key.
saveHistoricalData :: (MonadIO m) => Conduit (Either T.Text T.Text) m (Either T.Text T.Text)
saveHistoricalData = do 
    client <- await 
    liftIO $ threadDelay (10 * (10 ^ 6))
    liftIO $ Logger.debugM iModuleName $ "Saving historical data " `mappend` (show client)
    liftIO $ Prelude.putStrLn $ "saving historical data " `mappend` (show client)
    case client of 
        Nothing -> do 
            return()
            yield $ Left "Nothing to process"
        Just sym -> do 
            case sym of
                Right x -> do 
                    _ <- liftIO $ insertHistoricalIntoDb (T.unpack x)
                    yield $ Right x
                    return $ Right x 
                Left y -> do 
                    yield $ Left $ T.pack $ "Nothing to save " `mappend` (show y)
                    return $ Left $ T.pack $ "Nothing to save "
            saveHistoricalData          
    

parseOptionChainValue :: T.Text -> Float
parseOptionChainValue = parse_float_with_maybe . T.unpack

getBidRatio :: OptionChain -> BidRatio 
getBidRatio x = BidRatio (parseOptionChainValue . optionChainLastBid $  x) (parseOptionChainValue . optionChainStrike $ x)

queryOptionChain aNickName o = (\e@(SomeException a) -> return $ (GC.Reply, Left . appError $ show e)) `handle` 
    do 
        x <- case (parse parseJSON o :: Result QueryOptionChain) of 
                Success r@(QueryOptionChain ni cType underlying _) -> do 
                    -- Limit the size
                    optionChain <- dbOps $ selectList [OptionChainUnderlying ==. underlying] []
                    optionChainE <- Control.Monad.forM optionChain (\(Entity id x) -> return x)
                    return $ Right $ 
                        QueryOptionChain ni cType underlying (Prelude.take 50 optionChainE)
                Error s ->  return $ Left $ appError $ "Query option chain for a company failed  " <> s
        return (GC.Reply, x)

saveOptionChains :: (MonadIO m) => Conduit (Either T.Text T.Text) m BS.ByteString
saveOptionChains = do 
    symbol <- await
    liftIO $ Logger.debugM iModuleName ("Using symbol " <> (show symbol))
    liftIO $ threadDelay (10^6) -- a second delay  
    case symbol of 
        Nothing -> return () 
        Just x -> do 
            liftIO $ Logger.debugM iModuleName ("Saving option chains for " `mappend` (show x))
            case x of 
                (Right aSymbol) -> do 
                    liftIO $ Logger.debugM iModuleName ("Inserting into db " `mappend` (show x))
                    d <- liftIO defaultExpirationDate
                    i <- liftIO $ insertOptionChainsIntoDb (BS.pack $ T.unpack aSymbol) d
                    yield $ BS.pack $ "Option chains for " `mappend` 
                                    (T.unpack aSymbol) `mappend` " retrieved: "
                                    `mappend` (show i)                  
                (Left aSymbol) -> do 
                    liftIO $ Logger.errorM iModuleName $ "Not parsing symbol"  `mappend` (show aSymbol)
                    yield $ BS.pack $ "Option chain not parsed for " `mappend` (show aSymbol)
            saveOptionChains



insertHistoricalIntoDb xS = do 
    x1 <- getHistoricalData (BS.pack xS)
    Prelude.putStrLn $ show x1
    Logger.debugM iModuleName $ ("Inserting " `mappend` (show xS) `mappend` " database")
    case x1 of 
        Right x2 -> do 
            x <- Data.Vector.forM x2 
                    (\x -> 
                    case x of 
                        Success y -> do 

                                insertHistoricalPrice y $ T.pack xS
                                return $ Right $ "Inserted  " `mappend`(show y)
                        _   -> return $ Left $ "Unable to process " `mappend` (show x))
            return $ Right x
        Left x2 -> do 
            liftIO $ Logger.errorM iModuleName ("Error Historical price "  `mappend` (show xS))
            return $ Left xS


insertOptionChainsIntoDb x y = do 
    Logger.debugM iModuleName ("Inserting " `mappend` show x `mappend` " " `mappend` show y)
    x1 <- getOptionChains x y
    Logger.debugM iModuleName (show x1) 
    case x1 of 
        Right x2 -> do 
                liftIO $ Logger.debugM iModuleName ("Option chains " `mappend` (show x1))
                x <- Data.Vector.forM x2 (\s -> case s of 
                        Success y -> insertOptionChain y
                            ) 
                return $ Right x
        Left x -> do
                liftIO $ Logger.errorM iModuleName ("Error processing option chain " `mappend` (show x))
                return $ Left x


setupEquities aFileName = do 
    liftIO $ Logger.infoM iModuleName $ "Setting up equities" `mappend` aFileName
    _ <- (\a@(SomeException e) -> do 
                _ <- Logger.errorM iModuleName ("Error :: " <> (show a))
                return $ [Left $ T.pack $ show a]
                ) `handle` 
                    (runResourceT $ 
                        B.sourceFile aFileName $$ B.lines =$= parseSymbol =$= saveSymbol 
                        =$= saveHistoricalData
                        =$ consume)
    liftIO $ Logger.infoM iModuleName $ "Setup for equities completed " `mappend` aFileName

setupOptions aFileName = do 
    liftIO $ Logger.infoM iModuleName $ "Setting up options" `mappend` aFileName
    _ <- runResourceT $ 
            B.sourceFile aFileName $$ B.lines =$= parseSymbol =$= saveSymbol 
                    =$= saveOptionChains 
                    =$ consume
    liftIO $ Logger.infoM iModuleName $ "Setup for options completed " `mappend` aFileName


startup = do 
    insertTradierProvider 
    x <- liftM2 mkDir (getEnv("DATA_DIRECTORY")) (getEnv("NASDAQ_LISTED_SYMBOL_FILE"))
    y <- liftM2 mkDir (getEnv("DATA_DIRECTORY")) (getEnv("OTHER_LISTED_SYMBOL_FILE"))
    setupEquities x 
    setupOptions x 
    setupEquities y
    setupOptions y 
    where 
        mkDir dataDir fileName = T.unpack $ T.intercalate "/" 
                [(T.pack dataDir), T.pack $ fileName]


startup_d = do 
    dataDirectory <- getEnv("DATA_DIRECTORY")
    _ <- insertTradierProvider 
    setupEquities $ T.unpack $ T.intercalate "/" [(T.pack dataDirectory), "nasdaq_10.txt"]


-- test query option chain 

testOptionChain aSymbol = queryOptionChain ("test"  :: String)
                        $ toJSON $ QueryOptionChain "test" "Read" aSymbol []



data TradierMarketDataServer = TradierServer 


instance MarketDataServer TradierMarketDataServer where 
    realtime a = return False
    pollingInterval a = tradierPollingInterval 
    runner i a n t = tradierRunner a n t 


toDouble :: StressValue -> Double 
toDouble (Percentage Positive x) =  fromRational x 
toDouble (Percentage Negative x) =  -1 * (fromRational x)
toDouble (BasisPoints x y )                                = 0.0 -- Need to model this better.
toDouble (StressValueError y) = 0.0


updateStressValue :: HistoricalPrice -> PortfolioSymbol -> [Stress] -> IO Double
updateStressValue a b stress = do 
        m <- return $ (historicalPriceClose a )
        q <- return $ T.unpack (portfolioSymbolQuantity b)
        qD <- return $ (parse_float q)
        stressM <- return stress 
        symbol <- return $ T.unpack $ portfolioSymbolSymbol b 
        sVT <- Control.Monad.foldM (\sValue s -> 
                case s of 
                    EquityStress (Equity sym) sV -> 
                        if sym == symbol then 
                            return $ sValue + (toDouble sV)
                        else 
                            return sValue
                    _ -> return sValue) 0.0 stressM 
        Logger.debugM iModuleName $ "Total stress " `mappend` (show sVT) `mappend` "->" `mappend` (show stress)
        return (m * qD * (1 - sVT))



-- Refactoring note: move this to market data api.
tradierPollingInterval :: IO Int 
tradierPollingInterval = getEnv("TRADIER_POLLING_INTERVAL") >>= \x -> return $ parse_time_interval x

type CommandType = T.Text

computeHistoricalStress :: NickName -> [HistoricalPrice] -> PortfolioSymbol -> [Stress] -> IO [Either T.Text PortfolioStressValue]
computeHistoricalStress nickName prices s stresses = Control.Monad.mapM  (\m -> do  
                                stress <- updateStressValue m s stresses
                                daoToDto <- daoToDtoDefaults (unN nickName) s 
                                case daoToDto of 
                                    Right dto -> return $ Right $ 
                                            PortfolioStressValue 
                                            (unN nickName)
                                            "HistoricalStressValueCommand" 
                                            (historicalPriceDate m) 
                                            dto  
                                            stress
                                    Left x -> return $ Left x 
                            )prices 



-- The method is too complex. Need to fix it. 
-- Get all the symbols for the users portfolio,
-- Send a portfolio update : query the portfolio object
-- get the uuid and then map over it.


tradierRunner :: App -> WSConn.Connection -> T.Text -> Bool -> IO ()
tradierRunner app conn nickName terminate = 
    if(terminate == True) then do 
        Logger.infoM iModuleName "Market data thread exiting" 
        return ()
    else do 
        Logger.debugM iModuleName "Waiting for data"
        tradierPollingInterval >>= \x -> threadDelay x
        mySymbols <- Portfolio.queryUniqueSymbols nickName
        Logger.debugM iModuleName $ "mkSymbols" <> (show mySymbols)
        a2   <- atomically $ MarketDataAPI.getActivePortfolio nickName app  
        marketDataMap <- MarketDataAPI.queryMarketData
        upd <- Control.Monad.mapM (\x -> do
                activeScenario   <- atomically $ MarketDataAPI.getActiveScenario app nickName
                val <- return $ Map.lookup (portfolioSymbolSymbol x) marketDataMap 
                (stressValue, p) <- case val of 
                                                Just v -> do 
                                                    c <- updateStressValue v x activeScenario
                                                    return (c, x {portfolioSymbolValue = T.pack $ show $ 
                                                                        (historicalPriceClose v) * 
                                                                        (parse_float $ (T.unpack $ portfolioSymbolQuantity x))}) 
                                                Nothing -> return (0.0, x)
                pUUID <- Portfolio.queryPortfolioUUID $ portfolioSymbolPortfolio x
                case pUUID of 
                        Right y -> return $ daoToDto PortfolioSymbol.P_Update y
                                        nickName nickName nickName p $ (T.pack . show) stressValue
                        Left z -> return $ daoToDto PortfolioSymbol.P_Update z
                                        nickName nickName nickName p $ (T.pack . show) stressValue
                ) mySymbols

        Control.Monad.mapM_  (\p -> do
                liftIO $ Logger.debugM iModuleName ("test " `mappend` (show $ Util.serialize p))
                delay <- tradierPollingInterval
                liftIO $ threadDelay $ delay                
                liftIO $ WSConn.sendTextData conn (Util.serialize p) 
                return p 
                ) upd 
        stressValues <- handle (\x@(SomeException e) -> do 
                                    Logger.errorM iModuleName (show x) 
                                    return []
                                ) $ do 
                            Control.Monad.mapM (\p -> do 
                                delay <- tradierPollingInterval
                                liftIO $ threadDelay $ delay
                                h <- getHistoricalPrice $ portfolioSymbolSymbol p 
                                activeScenario <- liftIO . atomically $ getActiveScenario app nickName
                                computeHistoricalStress (NickName nickName) h p activeScenario) mySymbols

        Logger.debugM iModuleName "Computing stress values"
        Control.Monad.mapM_ (\p -> do 
                tradierPollingInterval >>= liftIO . threadDelay 
                Control.Monad.mapM_ (\q -> do 
                        payload <- return . Util.serialize $ q
                        Logger.debugM iModuleName $ "Sending payload " <> (T.unpack payload)
                        liftIO $ WSConn.sendTextData conn payload)
                    p) stressValues
        
        tradierRunner app conn nickName False



