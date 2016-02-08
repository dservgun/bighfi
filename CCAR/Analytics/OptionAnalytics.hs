module CCAR.Analytics.OptionAnalytics
	(OptionAnalyticsServer(..))
 where

import 							Data.Bits
import 							Network.Socket
import 							Network.BSD
import 							Data.List as List
import 							System.IO 
import 							Data.Text as T
import 							GHC.Generics
import 							Data.Data
import 							Data.Monoid (mappend, (<>))
import 							Data.Typeable 
import 							Data.Aeson
import 							CCAR.Main.Util as Util
import 							CCAR.Parser.CSVParser as CSVParser
import 							System.Log.Logger as Logger
import 							CCAR.Main.DBUtils 
import 							Database.Persist
import 							Database.Persist.TH 
import							CCAR.Data.MarketDataAPI as MarketDataAPI 
														(queryMarketData
														, queryOptionMarketData
														, MarketDataServer(..))
import 							CCAR.Model.Portfolio as Portfolio 
import 							CCAR.Model.PortfolioSymbol as PortfolioSymbol 
import 							Data.Map as Map 
import 							Data.Set as Set
import							System.IO 
import							Control.Monad.IO.Class(liftIO)
import							Control.Concurrent(threadDelay)
import							Control.Monad
import 							CCAR.Main.Application
import 							Control.Concurrent.STM.Lifted
import 							Network.WebSockets.Connection as WSConn
import							Control.Exception(catch, SomeException(..))
import							Text.ParserCombinators.Parsec
import							Control.Applicative
import							Numeric(readSigned, readFloat, readDec)
import           				Control.Monad.IO.Class  (liftIO)
import							Control.Exception(handle)
import							System.Environment
import							CCAR.Main.Util as Util(parse_time_interval)
import							CCAR.Analytics.Server
import							CCAR.Analytics.OptionPricer
import							Control.Monad.Trans.Reader
import							CCAR.Main.GroupCommunication
import 							Control.Concurrent.Async as A (waitSTM, wait, async
									, cancel, waitEither, waitBoth, waitAny
                        			, concurrently,asyncThreadId)

import 							GHC.Conc(labelThread)
import 							Debug.Trace(traceEventIO)
import							Control.Parallel.MPI.Simple



iModuleName = "CCAR.Analytics.OptionAnalytics"

data OptionServer = OptionServer {
	hostName :: String
	, portNumber :: String
} deriving (Show)

defaultOptionServer = OptionServer "localhost" "20000"

optionPricer :: OptionServer -> IO ServerHandle 
optionPricer a@(OptionServer hostName port) = do 
	addrinfos <- getAddrInfo Nothing (Just hostName) (Just port)
	let serverAddr = List.head addrinfos
	sock <- socket (addrFamily serverAddr) 
					Stream defaultProtocol
	setSocketOption sock KeepAlive 1
	connect sock $ addrAddress serverAddr
	h <- socketToHandle sock ReadWriteMode 
	hSetBuffering stdout LineBuffering
	hSetBuffering h (LineBuffering) 
	return $ ServerHandle h 



closeOptionPricer :: ServerHandle -> IO () 
closeOptionPricer h = hClose (sHandle h)


p_optionStrike = do 
	s <- getInput
	case readSigned readFloat s of 
		[(n, s')] -> n <$ setInput s'
		_		  -> Control.Applicative.empty 
parse_option_strike input = 
	case parse p_optionStrike ("unknown") input of 
		Right x -> x 
		Left _ -> 0.0

parse_float = parse_option_strike

parse_float_j = do 
	s <- getInput 
	string "Just " 
	s <- getInput
	case readSigned readFloat s of 
		[(n, s')] -> n <$ setInput s'
		_		  -> Control.Applicative.empty 


parse_float_with_maybe input = do 
	case parse parse_float_j ("Unknown") input of 
		Right x -> x 
		Left _ -> 0.0

computeBidRatio :: T.Text -> Double -> Double
computeBidRatio x y = (parse_float_with_maybe $ T.unpack x) /y 


getPricer marketDataMap option = do 
	y <-liftIO $ return $ Map.lookup (optionChainUnderlying option) (marketDataMap) 
	case y of 
		Just x -> do 
			optionSpotPrice <- return $ historicalPriceClose x 
			strikePrice <- return $ parse_option_strike $ T.unpack $ optionChainStrike option 
			bidRatio <- return $ computeBidRatio (optionChainLastBid option) strikePrice
			return $ OptionPricer (optionChainUnderlying option) 
							(optionChainOptionType option)
							"A"
							optionSpotPrice
							strikePrice
							riskFreeInterestRate 
							dividendYield 
							volatility 
							timeToMaturity 
							randomWalks 
							price
							option
							bidRatio
							"OptionAnalytics"
			where 
				riskFreeInterestRate = 0.02
				dividendYield = 0.0
				volatility = 0.2
				timeToMaturity = 0.25
				randomWalks = 100000
				price = 0.00000000000001


analytics sHandle marketDataMap option = do 
	y <- liftIO $ return $ Map.lookup (optionChainUnderlying option) marketDataMap
	case y of 
		Just x -> do  
			optionSpotPrice <- return (historicalPriceClose x)
			Logger.debugM iModuleName $ show option	
			strikePrice <- return $ 
					parse_option_strike $ T.unpack $ optionChainStrike option

			bidRatio <- return $ computeBidRatio (optionChainLastBid option) strikePrice
			Logger.debugM iModuleName ("BidRatio " `mappend` (show bidRatio))
			pricer <- return $ OptionPricer (optionChainUnderlying option) 
							(optionChainOptionType option)
							"A"
							optionSpotPrice
							strikePrice
							riskFreeInterestRate 
							dividendYield 
							volatility 
							timeToMaturity 
							randomWalks 
							price
							option
							bidRatio
							"OptionAnalytics"
			writeOptionPricer pricer sHandle

	where 
		riskFreeInterestRate = 0.02
		dividendYield = 0.0
		volatility = 0.2
		timeToMaturity = 0.25
		randomWalks = 100000
		price = 0.00000000000001


testOptionPricer = 
		OptionPricer "TEVA" "C" "A" 
				100.0 100.0 
				0.05 0.0 
				0.2 0.25 
				100000 0.00000000000001


-- TODO: Convert this to json. Or add request type so the server
-- can process it.
fromCSV:: String -> Either ParseError [String]
fromCSV = \x -> CSVParser.parseLine x

toCSV :: OptionPricer -> String
toCSV (OptionPricer a b c
		d e 

		f g 
		h i 
		j k _ _ _) = List.intercalate "|" [show a , show b , show c
				, "" <> show d, "" <> show e
				, show f, show g 
				, show h , show i 
				, show j, show k] 
writeOptionPricer :: OptionPricer -> ServerHandle -> IO OptionPricer
writeOptionPricer pricer x = do 
	hPutStrLn (sHandle x) (toCSV pricer)
	hFlush (sHandle x)
	nextString <- hGetLine (sHandle x)
	parsedString <- return $ fromCSV nextString
	putStrLn $ show parsedString
	p <- case parsedString of
		Right x -> do 
			p0 <- return $ Util.parse_float $ x !! 10
			return pricer  {price = p0 }
		Left _ -> return pricer
	Logger.debugM iModuleName $ "Received " <> nextString
	hFlush stdout
	return p 
data OptionAnalyticsServer = OptionAnalyticsServer 


instance MarketDataServer OptionAnalyticsServer where 
    realtime a = return False
    pollingInterval a = analyticsPollingInterval 
    runner i a n t = analyticsRunner a n t 


-- Refactoring note: move this to market data api.
analyticsPollingInterval :: IO Int 
analyticsPollingInterval = getEnv("ANALYTICS_POLLING_INTERVAL") >>= \x -> return $ (parse_time_interval x)




getOptionMarketData :: T.Text -> IO [OptionChain]
getOptionMarketData nickName = do  
    mySymbols <- Portfolio.queryUniqueSymbols nickName
    marketData <- MarketDataAPI.queryOptionMarketData mySymbols 
    Control.Monad.mapM (\x@(Entity k val) -> return val ) marketData
    			
	

analyticsRunner :: App -> WSConn.Connection -> T.Text -> Bool -> IO ()
analyticsRunner app conn nickName terminate = 
    if(terminate == True) then do 
        Logger.infoM iModuleName "Analytics data thread exiting" 
        return ()
    else handle(\x@(SomeException e) -> do 
    	Logger.infoM iModuleName "Exiting analytics thread."
    	return ()) $ do 	    
	    sH <- optionPricer defaultOptionServer 
	    marketDataMap <- MarketDataAPI.queryMarketData
	    a <- A.async (pricerReaderThread app conn nickName marketDataMap)
	    b <- A.async (pricerWriterThread app conn nickName marketDataMap)
	    labelThread (A.asyncThreadId a ) ("Pricer reader thread " ++ (T.unpack nickName))
	    labelThread (A.asyncThreadId b) ("Pricer writer thread " ++ (T.unpack nickName))
	    A.waitAny [a, b]
	    Logger.infoM iModuleName "Exiting pricer threads"

data PricerState = PricerState{
		app :: App
		, conn :: WSConn.Connection
		, nickName :: T.Text
		, marketData :: Map T.Text HistoricalPrice
	}
type PriceReader = ReaderT PricerState IO 


--pricerReaderThread :: App -> WSConn.Connection -> NickName -> IO ()
pricerReaderThread a c n m = do 
	x <- flip runReaderT (PricerState a c n m) $ do 
			PricerState app conn nickName marketData <- ask
			opts <- liftIO $ getOptionMarketData nickName
			pricers <- Control.Monad.mapM( \x -> do 
				pricer <- liftIO $ getPricer  marketData x 
				conns <- atomically $ getClientState nickName app
				Control.Monad.mapM( \c -> atomically $ writeTChan (pricerWriteChan c) pricer) conns) opts
			return pricers
	pricerReaderThread a c n m

pricerWriterThread a c n m = do 
	sH <- optionPricer defaultOptionServer
	x <- flip runReaderT (PricerState a c n m) $ atomically $ do
					clientStates <- getClientState n a 
					case clientStates of 
						clientState:_ -> readTChan (pricerReadChan clientState)
	pricer2 <- writeOptionPricer x sH

	liftIO $ analyticsPollingInterval >>= threadDelay
	liftIO $ WSConn.sendTextData c (Util.serialize pricer2)
   	pricerWriterThread a c n m
