{--License: license.txt --}

{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies, OverloadedStrings #-}
module CCAR.Main.Driver
    (driver)
where 

import Data.Set as Set 
import Data.Map as Map
import Data.Ratio
import Yesod.Core
import Yesod.WebSockets as YWS
import Control.Monad.Trans.Control    (MonadBaseControl (liftBaseWith, restoreM))
import Network.WebSockets.Connection as WSConn
import Network.WebSockets 
import Yesod.Static
import Control.Exception hiding(Handler)
import qualified GHC.Conc as GHCConc
import CCAR.Parser.CCARParsec
import CCAR.Model.PortfolioT
import CCAR.Model.CcarDataTypes
import CCAR.Main.GroupCommunication
import Control.Monad (forever, void, when, liftM, filterM, foldM)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Writer 
import Control.Monad.Error
import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.Async as A (waitSTM, wait, async, cancel, waitEither, waitBoth, waitAny
                        , concurrently,asyncThreadId)
import Control.Monad.IO.Class(liftIO)
import Control.Monad.Logger(runStderrLoggingT)
import Data.Time
import Data.Time.Clock
import Data.Monoid ((<>), mappend)
import Control.Concurrent.STM.Lifted
import Data.Text as T  hiding(foldl, foldr)
import Data.Aeson as J
import Control.Exception(SomeException)
import Control.Applicative as Appl
import Data.Aeson.Encode as En
import Data.Aeson.Types as AeTypes(Result(..), parse)
import Data.Text.Lazy.Encoding as E
import Data.Text.Lazy as L hiding(foldl, foldr)
import System.IO
import Data.Map as Map 
import Data.HashMap.Lazy as LH (HashMap, lookup, member)
import qualified CCAR.Model.Person as Us 
import qualified CCAR.Model.CCAR as CCAR
import qualified CCAR.Model.UserTermsAndConditions as Ust 
import qualified CCAR.Model.Survey as Survey 
import Data.ByteString as DBS 
import Data.ByteString.Char8 as C8 
import System.Environment
import CCAR.Data.MarketDataAPI(MarketDataServer(..), updateActiveScenario, getActivePortfolio)
import CCAR.Main.Application(App(..), updateClientState)
import CCAR.Main.Util as Util
import GHC.Generics
import Data.Data
import Data.Typeable 
import Database.Persist.Postgresql as DB
import Database.Persist 
import Data.Map as IMap
import CCAR.Data.ClientState as ClientState
import CCAR.Main.DBUtils
import CCAR.Main.GroupCommunication as GroupCommunication
import CCAR.Main.UserJoined as UserJoined 
import CCAR.Main.Application
import CCAR.Command.ApplicationError 
import CCAR.Model.Person
import CCAR.Model.Country as Country
import CCAR.Model.Company as Company 
import CCAR.Model.Project as Project
import CCAR.Model.ProjectWorkbench as ProjectWorkbench
import CCAR.Model.Portfolio as Portfolio
import CCAR.Model.PortfolioSymbol as PortfolioSymbol
import CCAR.Entitlements.Entitlements as Entitlements
import CCAR.Data.TradierApi as TradierApi
import CCAR.Analytics.OptionAnalytics as OptionAnalytics
import CCAR.Model.Login as Login
import CCAR.Model.UserOperations as UserOperations
import CCAR.Analytics.EquityAnalytics as EquityAnalytics (startup)
import GHC.Real
-- logging
import System.Log.Formatter as LogFormatter
import System.Log.Handler(setFormatter)
import System.Log.Handler.Simple as SimpleLogger
import System.Log.Handler.Syslog as SyslogLogger 
import System.Log.Logger as Logger
import System.Log as Log
import CCAR.Entitlements.GmailAuthentication as GmailAuthentication
import Network.URI
import Network.HTTP.Client as HttpClient
import Network.HTTP.Conduit 
import Network.HTTP.Types as W 
import GHC.Conc(labelThread)
import Debug.Trace(traceEventIO)
import                          CCAR.Analytics.MarketDataLanguage(evalMDL)
import                          CCAR.Data.EquityBenchmark as EquityBenchmark
import  CCAR.Data.ClientState(runAP)
import CCAR.Main.GmailAuth

iModuleName :: String 
iModuleName = "CCAR.Main.Driver"


connStr = getConnectionString


data CheckPassword = CheckPassword {pwNickName :: T.Text, pwPassword :: T.Text, 
                passwordValid :: Maybe Bool, 
                numberOfAttemmpts :: Integer}
                    deriving(Show, Eq, Typeable, Data, Generic)

instance ToJSON CheckPassword 
instance FromJSON CheckPassword




data UserTermsOperations = UserTermsOperations {utOperation :: Ust.CRUD
                                        , terms :: Maybe TermsAndConditions} 
                                                deriving(Show, Eq)


data KeepAliveCommand = KeepAliveCommand {
        kaNickName :: T.Text
        , kaCommandType :: T.Text 
        , keepAlive :: T.Text } deriving(Show, Eq)

instance ToJSON KeepAliveCommand where 
    toJSON (KeepAliveCommand k1 k2 k3) = 
        object ["nickName" .= k1 
                , "commandType" .= k2 
                , "keepAlive" .= k3]

instance FromJSON KeepAliveCommand where 
    parseJSON (Object a) = KeepAliveCommand <$> 
        a .: "nickName" <*>
        a .: "commandType" <*>
        a .: "keepAlive"
    parseJSON _ = Appl.empty




type From = T.Text
type To = T.Text



data UserPreferences = UserPreferences {prefs :: T.Text} deriving (Show, Eq, Generic)

genTermsAndConditions (TermsAndConditions t des accept) = object ["title" .= t
                                            , "description" .= des
                                            , "acceptDate" .= accept]
genCommandKeepAlive a  = object ["KeepAlive" .= a
                                , "commandType" .= ("KeepAlive" :: T.Text)]



instance ToJSON UserTermsOperations where
    toJSON (UserTermsOperations o t) = object ["utOperation" .= o, "terms" .= t]


parseKeepAlive v = v .: "keepAlive"

parsePerson = \v -> Person <$>  
                v .: "firstName"
                <*> v .: "lastName"
                <*> v .: "nickName"
                <*> v .: "password"
                <*> v .: "deleted"
                <*> v .: "lastLoginTime"
                

parseTermsAndConditions v = TermsAndConditions <$>
                        v .: "title" <*>
                        v .: "description" <*>
                        v .: "acceptDate"

iParseJSON :: (FromJSON a) => T.Text -> Either String (Maybe a)
iParseJSON = J.eitherDecode . E.encodeUtf8 . L.fromStrict

pJSON :: (FromJSON a) => T.Text -> IO (Either String (Maybe a))
pJSON  aText = do
    Logger.infoM  iModuleName ( T.unpack aText)
    return $ iParseJSON aText


instance Yesod App
type State = T.Text 
type AuthCode = T.Text
type Url = T.Text
type OpenIdScope = T.Text

mkYesod "App" [parseRoutes|
/chat HomeR GET
-- | The request object to make a request with the application details to 
-- | gmail.
/gmailOauthRequest/#EmailHint/#OpenIdScope GmailOauthR GET
-- | Setup gmail call back
/gmailOauthCallback GmailOauthCallbackR GET
|]



checkPassword :: CheckPassword -> IO (DestinationType, CheckPassword) 
checkPassword b@(CheckPassword personNickName password _ attempts) = do
    chk <- checkLoginExists(personNickName) 
    case chk of 
        Nothing -> return $ (GroupCommunication.Reply, b {passwordValid = (Just False)})
        Just (Entity aid a) -> do
            return $ (Reply, b {passwordValid = validatePassword (personPassword a) b
                                , numberOfAttemmpts = attempts + 1 })

validatePassword :: T.Text -> CheckPassword -> Maybe Bool 
validatePassword dbPassword input = Just $ dbPassword == (pwPassword input)


processCommandValue :: App -> T.Text -> Value -> IO (DestinationType, T.Text)
processCommandValue app nickName aValue@(Object a)   = do  
    case cType of 
        Nothing -> return $ (GroupCommunication.Reply, ser $ 
                                appError ("Unable to process command" :: T.Text))
        Just aType -> do 
            currentTime <- getCurrentTime
            Logger.debugM "CCAR" ("Updating keep alive time " ++ (show currentTime))
            atomically $ do
                clientStates  <- getClientState nickName app 
                mapM_ (\_ -> updateClientState nickName app currentTime) clientStates
            case aType of 
                String "KeepAlive" -> do 
                        case (parse parseJSON aValue :: Result KeepAliveCommand) of
                            Success r -> return (GroupCommunication.Reply, ser r)
                            Error s -> 
                                return (
                                    GroupCommunication.Reply, 
                                    ser $ appError $ 
                                        "Parse Keep alive failed" ++ s ++ (show a))
                String "ActivePortfolio" -> do 
                        Logger.debugM "CCAR" $ "Updating active portfolio " ++ (show a)
                        (dType, value) <- processActivePortfolio nickName app (Object a)
                        return (dType, ser value)
                String "SendMessage" -> do 
                        (dType, value) <- processSendMessage (Object a)
                        return (dType, ser value)
                String "ManageCompany" -> Company.manageCompany (NickName nickName) (Object a)
                String "SelectAllCompanies" -> Company.queryAllCompanies nickName (Object a)
                String "ManageProject" -> Project.manageProject nickName (Object a)
                String "SelectActiveProjects" -> Project.queryActiveProjects nickName (Object a)
                String "QuerySupportedScripts" -> ProjectWorkbench.querySupportedScripts nickName (Object a)
                String "QueryActiveWorkbenches" -> ProjectWorkbench.queryActiveWorkbenches (Object a)
                String "PortfolioSymbolTypesQuery" -> Portfolio.queryPortfolioSymbolTypes nickName (Object a)
                String "PortfolioSymbolSidesQuery" ->Portfolio.queryPortfolioSymbolSides nickName (Object a)
                String "ManageWorkbench" -> ProjectWorkbench.manageWorkbench (Object a)
                String "ExecuteWorkbench" -> do                            
                            atomically $ do 
                                clientStates <- getClientState nickName app 
                                mapM_ (\cs -> writeTChan (jobWriteChan cs) (Object a)) clientStates                            
                            return(GroupCommunication.Reply, 
                                ser $ ("Execute workbench received" :: T.Text))
                --ProjectWorkbench.executeWorkbench(Object a)
                String "ManageSurvey" -> Survey.manageSurvey nickName (Object a)
                -- Assign a user to a company.
                String "AssignCompany" -> Company.assignUserToCompany nickName (Object a)
                String "QueryPortfolios" -> Portfolio.manageSearch (NickName nickName) (Object a)
                String "ManagePortfolio" -> Portfolio.manage (NickName nickName) (Object a)
                String "ManagePortfolioSymbol" -> PortfolioSymbol.manage (NickName nickName) (Object a)
                String "QueryPortfolioSymbol" -> PortfolioSymbol.manageSearch (NickName nickName) (Object a)
                String "ManageEntitlements" -> Entitlements.manage (NickName nickName) aValue 
                            >>= \(gc, either) -> 
                            return (gc, Util.serialize 
                                (either :: Either ApplicationError 
                                    Entitlements.EntitlementT)
                                )
                String "QueryEntitlements" -> Entitlements.query nickName aValue 
                            >>= \(gc, either) -> 
                                    return (gc, 
                                        Util.serialize 
                                        (either :: 
                                                Either ApplicationError 
                                                Entitlements.QueryEntitlementT))
                String "ManageCompanyEntitlements" -> Entitlements.manage (NickName nickName) aValue 
                            >>= \(gc, either) ->
                            return (gc , 
                            Util.serialize 
                            (either :: Either ApplicationError 
                                        Entitlements.CompanyEntitlementT))
                String "QueryCompanyEntitlements" -> Entitlements.query nickName aValue 
                            >>= \(gc, either) ->
                        return (gc, Util.serialize
                                (either :: 
                                    Either ApplicationError 
                                        Entitlements.QueryCompanyEntitlementT))
                String "QueryCompanyUsers" -> Company.query nickName aValue 
                            >>= \(gc, either) -> 
                                return (gc, Util.serialize 
                                        (either :: Either ApplicationError 
                                                    Company.QueryCompanyUsers))
                String "QueryOptionChain" -> TradierApi.query nickName aValue
                            >>= \(gc, either) -> 
                                do 
                                Logger.debugM iModuleName $ show either
                                return (gc, Util.serialize 
                                        (either :: Either ApplicationError 
                                                        TradierApi.QueryOptionChain))
                String "Login" -> 
                            Login.query nickName aValue 
                                >>= \(gc, result) -> 
                                    return (gc, 
                                            Util.serialize
                                            (result ::Either ApplicationError Login))
                String "ManageUser" ->
                        UserOperations.manage (NickName nickName) aValue 
                            >>= \(gc, either) ->
                                return(gc, Util.serialize 
                                        (either :: Either ApplicationError UserOperations))
                String "CCARUpload" -> 
                        CCAR.manage (NickName nickName) aValue
                            >>= \(gc, either) -> 
                                return (gc, Util.serialize 
                                        (either :: Either ApplicationError CCAR.CCARUpload)) 
                String "QueryMarketData" -> do 
                        Logger.debugM iModuleName $ "Query market data " <> (show a)
                        y <- runMaybeT $ do 
                            s1  <- return $ LH.lookup "symbol" a
                            pid <- return $ LH.lookup "portfolioId" a 
                            case (s1, pid) of 
                                (Just (String aName), Just (String portId))  -> lift $ evalMDL aName portId

                        r <- case y of 
                                Just x -> return $ Right x
                                Nothing -> return $ Left $ ("Error in QueryMarketData" :: T.Text)
                        return (GroupCommunication.Reply 
                            , Util.serialize r)
                String "ParsedCCARText" -> do 
                        (gc, x) <- CCAR.parseCCMessage nickName aValue 
                        case x of 
                            Left x -> return (gc, Util.serialize x) 
                            Right (CCAR.CCARText uploadedBy name y) -> do
                                Logger.infoM iModuleName "Calling parsed ccar text..." 
                                y2 <- return $ readExprTree y 
                                Logger.debugM iModuleName $ "Scenarios " ++ (show y2)
                                atomically $ updateActiveScenario app nickName y2
                                cState <- atomically $ getClientState nickName app
                                Logger.debugM iModuleName $ "Client state " ++ (show cState)
                                return (gc, Util.serialize y)

                String "UserBanned" -> do
                        c <- return $ (parse parseJSON aValue :: Result UserBanned)
                        case c of
                            Success u@(UserJoined.UserBanned a1) -> do
                                bConns <- atomically $ getClientState a1 app 
                                mapM_ (\bconn -> WSConn.sendClose (connection bconn)
                                        ("Bye"
                                            :: T.Text) `catch` (
                                            \c@(ConnectionClosed) -> atomically $ deleteConnection app a1                    
                                            )) bConns  -- To handle multiple connections to a client.
                                return (GroupCommunication.Broadcast, ser u)
                            Error s ->  return (GroupCommunication.Reply 
                                    , ser $ appError $ "parse manage user failed " ++ s )
                _ ->                                                
                    return 
                         ( GroupCommunication.Reply
                         , ser $ appError ("Unable to process command " ++ (show aType)))
    where 
        cType = lookupTag aValue "commandType"
        ser a = L.toStrict $ E.decodeUtf8 $ En.encode a 


lookupTag :: Value -> T.Text -> (Maybe Value)
lookupTag (Object a ) aTag = LH.lookup aTag a 

data DriverError = NickNameNotFound T.Text 
                | InvalidCommand T.Text
                | AuthenticationFailed T.Text
                | LoginFailed T.Text 
                | SomeThreadsFailed T.Text 
                | ClientDisconnected T.Text  
                | UndefinedDriverError T.Text
                | MultipleLogins T.Text
                deriving(Show, Eq, Typeable, Data, Generic)


instance Error DriverError where 
    noMsg =  UndefinedDriverError "We dont know what happened here!"
    strMsg = UndefinedDriverError . pack 
            where pack = T.pack

newtype NickNameError a = NickNameError {
    runP :: ErrorT DriverError IO a
}deriving (Applicative, Functor, Monad, MonadError DriverError) 



nickName2 :: Maybe Value -> NickNameError T.Text
nickName2 aCommand = do 
    case aCommand of 
        Nothing -> throwError $ InvalidCommand "Invalid command"
        Just (Object a) -> do 
            case (LH.lookup "nickName" a) of 
                Just x -> case x of 
                            String x -> return x 
                            _   -> throwError nn 
                Nothing -> throwError nn
    where 
        nn = NickNameNotFound "NickName tag not found"



processLoginMessages :: App -> WSConn.Connection -> T.Text -> Maybe Value  -> MaybeT IO (DestinationType, T.Text)
processLoginMessages app conn aNickName Nothing = 
    return (GroupCommunication.Reply, "Invalid value")
    
processLoginMessages app conn aNickName (Just (Object aDictionary)) = do 
    Just commandType <- return $ LH.lookup "commandType" aDictionary
    case commandType of 
        String "Login" -> 
                    liftIO $ Login.query aNickName (Object aDictionary)
                    >>= \(GroupCommunication.Reply, (result :: Either ApplicationError Login)) -> 
                        return (GroupCommunication.Reply, aNickName)

processIncomingMessage :: App -> WSConn.Connection -> T.Text ->  Maybe Value -> IO (DestinationType , T.Text)
processIncomingMessage app conn aNickName aCommand = do 
    Logger.debugM iModuleName $ show aCommand
    case aCommand of 
        Nothing -> do 
                (x, y) <- runWriterT $ do 
                    tell [("Processing error " ++ (show aNickName))]
                    
                    result <- return (appError ("Unknown error" :: T.Text)) 
                    return $ (GroupCommunication.Reply, L.toStrict $ E.decodeUtf8 $ En.encode  result)
                Logger.errorM iModuleName  (show y)
                return x                     
        Just (Object a) -> do 
                 (processCommandValue app aNickName (Object a)) `catch`
                    (\e -> do
                            Logger.errorM iModuleName $  ("Exception "  ++ show (e :: PersistException)) 
                            atomically $ deleteConnection app aNickName
                            return (GroupCommunication.Broadcast, 
                                    Util.serialize $ UserJoined.userLeft aNickName)
                            )
                    



deleteConnection :: App -> T.Text -> STM  () 
deleteConnection app nn = do 
            cMap <- readTVar nMap
            _ <-    writeTVar nMap (IMap.delete nn cMap)
            return ()
            where
                nMap = nickNameMap app


addConnection :: App -> WSConn.Connection ->  T.Text -> UTCTime -> STM ()
addConnection app aConn nn currentTime = do 
                nMap <- readTVar $ nickNameMap app 
                clientState <- GroupCommunication.createClientState nn aConn currentTime
                _ <- writeTVar (nickNameMap app) (IMap.insert nn clientState nMap)
                return ()

getAllClientIdentifiers :: App -> STM [ClientIdentifier]
getAllClientIdentifiers app@(App a c) = do 
    nMap <- readTVar c 
    return $ Map.keys nMap


countAllClients :: App ->  STM Int 
countAllClients app@(App a c) = do
    nMap <- readTVar c 
    return $ Map.size nMap

type TimeInterval = NominalDiffTime -- time in seconds

-- Return all clients that have been inactive for more than the interval
getStaleClients :: App -> TimeInterval -> UTCTime -> STM[ClientState]
getStaleClients app@(App a c) interval currentTime = do 
    nMap <- readTVar c 
    return $ IMap.elems $ filterWithKey (\k x -> staleClient x) nMap
    where 
        staleClient clientState  = (timeDiffs currentTime (lastUpdateTime clientState)) 
                                                >= (interval :: NominalDiffTime) 

        
getClientsWithFilter :: App -> T.Text -> (T.Text -> ClientState -> Bool) -> STM [ClientState]
getClientsWithFilter app@(App a c) nn f = do
    nMap  <- readTVar c 
    return $ IMap.elems $ filterWithKey f nMap

getAllClients :: App -> T.Text -> STM [ClientState]
getAllClients app@(App a c) nn = do
    nMap <- readTVar c 
    return $ IMap.elems $ filterWithKey (\k x-> nn /= (ClientState.nickName x)) nMap 



conv :: Result a -> Maybe a 
conv a = 
    case a of 
        Success r -> Just r 
        Error s -> Nothing


authenticateM :: WSConn.Connection -> T.Text -> App -> MaybeT IO (DestinationType, T.Text) 
authenticateM aConn aText app@(App a c) = do 
    Just o@(Object a) <- return $ J.decode . E.encodeUtf8 . L.fromStrict $ aText
    Just (r@(Login a b)) <- return . conv $ (parse parseJSON o :: Result Login) 
    Just nickName <- return $ fmap personNickName a 
    return (GroupCommunication.Reply, UserJoined.userJoined nickName)



authenticate :: WSConn.Connection -> T.Text -> App -> IO (DestinationType, T.Text)
authenticate aConn aText app@(App a c) = do 
    r <- runMaybeT $ authenticateM aConn aText app 
    case r of 
        Just x -> return x 
        Nothing -> return (GroupCommunication.Reply, "Invalid user name " :: T.Text)
{-        
    case aCommand of 
        Nothing -> return (GroupCommunication.Reply, 
                    L.toStrict $ E.decodeUtf8 $ En.encode 
                            $ appError ("Invalid command during login" :: T.Text))
        Just o@(Object a) -> do                
            result <- return $ (parse parseJSON o :: Result Login)
            case result of 
                Success (r@(Login a b)) -> do 
                        x <- runMaybeT $ do 
                            Just nickName <- return $ fmap personNickName a 
                            return $ UserJoined.userJoined nickName
                        case x of 
                            Nothing -> return(GroupCommunication.Reply, 
                                ser $ appError ("Invalid user name" :: T.Text))
                            Just y -> return (GroupCommunication.Reply, y)
                Error s -> 
                    return (GroupCommunication.Reply, T.pack s)
    where 
        aCommand = (J.decode  $ E.encodeUtf8 (L.fromStrict aText)) :: Maybe Value
-}


ser  = (L.toStrict) . (E.decodeUtf8) . (En.encode)

processUserLoggedIn :: WSConn.Connection -> T.Text -> App -> T.Text -> IO (DestinationType, T.Text) 
processUserLoggedIn aConn aText app@(App a c) nickName = do
    case aCommand of 
            Nothing -> return (GroupCommunication.Reply, 
                    ser $ appError ("Login has errors" :: T.Text))
            Just o@(Object a) -> do
                currentTime <- getCurrentTime
                Just commandType <- return $ LH.lookup "commandType" a
                case commandType of 
                    String "UserLoggedIn" -> do 
                        c <- return $ (parse parseJSON o :: Result UserLoggedIn)
                        case c of 
                            Success u@(UserJoined.UserLoggedIn a) -> do 
                                        atomically $ addConnection app aConn a currentTime 
                                        return $ (Broadcast, ser u)
                            _ -> return $ (GroupCommunication.Reply, ser  
                                                $ appError ("Invalid command during login" :: T.Text))                                
                    String "UserJoined" -> do 
                        c <- return $ (parse parseJSON o :: Result UserJoined)
                        case c of 
                            Success u@(UserJoined.UserJoined a) -> do 
                                        atomically $ addConnection app aConn a currentTime 
                                        return $ (Broadcast, ser u)
                            _ -> return $ (GroupCommunication.Reply, ser  
                                                $ appError 
                                                    ("Invalid command during login" :: T.Text))
                    String "ManageUser"-> do
                        Logger.debugM iModuleName  ("Manage user " `mappend`   
                                                        (T.unpack $ aText))
                        g@(gc, res) <- UserOperations.manage (NickName aText) o 
                        case res of 
                            Right x -> do 
                                    atomically $ addConnection app aConn nickName currentTime
                                    return (Reply, ser x)
                            Left y -> return $ (GroupCommunication.Reply
                                                    , ser $ appError (T.pack (show y)))
                        return (gc, ser (res :: Either ApplicationError UserOperations )) 
                    String "GuestUser" -> do 
                        result <- return $ (parse parseGuestUser a)
                        case result of 
                            Success (g@(UserJoined.GuestUser guestNickName)) -> do
                                    createGuestLogin (NickName guestNickName)
                                    atomically $ addConnection app aConn guestNickName  currentTime
                                    return $ (GroupCommunication.Broadcast, ser g)                          
                            Error errMessage ->  
                                    return (GroupCommunication.Reply 
                                        , ser $ appError
                                                $ ("Guest login failed ") `mappend`  errMessage)
                    String "Login" -> do 
                            atomically $ addConnection app aConn nickName currentTime 
                            return (GroupCommunication.Reply, aText) -- tuple the input up
                    String "KeepAlive" -> do 
                            atomically $ addConnection app aConn nickName currentTime 
                            return (GroupCommunication.Reply, aText)
                    _ -> return (GroupCommunication.Reply 
                                , ser $ appError 
                                        $ "process user logged in failed :  " ++ (show aText) )

            where 
                aCommand = (J.decode  $ E.encodeUtf8 (L.fromStrict aText)) :: Maybe Value


instance Show WSConn.Connection where
    show (WSConn.Connection o cType proto msgIn msgOut cl) = show proto 


startUserThreads :: App -> Network.WebSockets.Connection -> T.Text -> IO T.Text
startUserThreads app connection nickNameV = do 
        a <- (A.async (writerThread app connection nickNameV False))
        b <- (A.async (liftIO $ readerThread app nickNameV False))
        c <- (A.async $ liftIO $ jobReaderThread app nickNameV False)
        d <- (A.async $ liftIO $ runner TradierApi.TradierServer app connection nickNameV False)
        Prelude.mapM_ (\x@(a, label, nick) -> labelThread 
                                                (A.asyncThreadId a)
                                                (label ++ " " ++ nick)) 
                        [(a, "Writer thread", T.unpack nickNameV)
                        , (b, "Reader thread", T.unpack nickNameV)
                        , (c, "Job thread", T.unpack nickNameV)
                        , (d, "Market data thread" , T.unpack nickNameV)]
        A.waitAny [a, b, c, d]
        return "Threads had exception" 





validateClientState :: App -> Network.WebSockets.Connection -> T.Text -> ErrorT DriverError IO T.Text
validateClientState app connection = \command -> do 
        nickName <- runP $ nickName2 $ incomingDictionary command
        clientState <- atomically $ getClientState nickName app
        case clientState of 
            [] -> do 
                (destination, text) <- liftIO $ authenticate connection command app  
                processResult <- liftIO $ do  
                            _ <- (processClientLost app connection nickName command)
                                    `catch` 
                                    (\ a@(CloseRequest e1 e2) -> do  
                                        atomically $ deleteConnection app nickName
                                        return "Close request" )
                            a <- liftBaseWith (\run -> run $ liftIO $ startUserThreads app connection nickName)
                            return ("All threads exited " :: T.Text)
                return processResult 
            _ -> do 
                    liftIO $ WSConn.sendClose connection 
                        ("Active connection. Multiple logins not allowed. " `mappend` nickName)
                    return ("Multiple logins not allowed " :: T.Text)



-- Do not let multiple connections to the same nick name.
-- How do we allow multiple connections for handling larger data, such as
-- video or file upload?
-- Create a session id for a connection and send that token back to the client.
-- Subsequent request for another connection needs to be assigned the same token. 


ccarApp :: WebSocketsT Handler ()
ccarApp = do
        connection <- ask
        app <- getYesod
        command <- liftIO $ WSConn.receiveData connection
        error1  <- liftIO $ runErrorT $ validateClientState app connection command 
        _ <- case error1 of 
                Left driverError -> do 
                        liftIO $ WSConn.sendClose connection (T.pack $ show driverError)
                        return ("Close sent" :: T.Text)
        return ()



incomingDictionary aText = J.decode  $ E.encodeUtf8 $ L.fromStrict aText :: Maybe Value


{-- Both these methods are part of pre-login handshake. --}
{-- An exception while server is replying to client. --}
processClientLost app connection nickNameV iText = do
                    (command, nickNameFound) <- liftIO $ processIncomingMessage
                                app 
                                connection 
                                nickNameV
                                $ incomingDictionary iText
                    liftIO $ Logger.errorM iModuleName $ "Sending " ++ ( show nickNameFound)
                    WSConn.sendTextData connection nickNameFound
                    _ <- (processClientLeft connection app nickNameV) `catch`
                                    (\a@(SomeException e) -> do  
                                            atomically $ deleteConnection app nickNameV
                                            return ("Close request" :: T.Text))
                    return ("Threads exited" :: T.Text)

{- Stay inside the loop till the user answers with the correct passsword -}
processUserPassword connection app nickNameV = undefined

{-- Client hits a refresh or loses connection --}
processClientLeft connection app nickNameV = do
            command <- WSConn.receiveData connection
            (dest, text) <- liftIO $ processUserLoggedIn connection command app nickNameV
            Logger.debugM iModuleName $ "User logged in " ++ (show text)
            messageLimit <- liftIO $ getMessageCount nickNameV
            Logger.debugM iModuleName  $ "Using message limit " ++ (show messageLimit)
            messageHistory <- liftIO $ GroupCommunication.getMessageHistory messageLimit
            Logger.debugM iModuleName $ "After messageHistory " ++ (show nickNameV)
            atomically $ do 
                            clientStates <- case dest of 
                                Broadcast -> getAllClients app nickNameV
                                PrivateMessage t ->
                                    getClientState t app
                                _ ->
                                    getClientState nickNameV app           
                            --                              
                            mapM_ (\cs -> writeTChan (writeChan cs) (text)) clientStates                                        
                            clientStates <- getClientState nickNameV app 
                            mapM_ (\cs -> writeTChan (writeChan cs) 
                                    (UserJoined.userLoggedIn (ClientState.nickName cs))) clientStates
                            currentClientState <- getClientState nickNameV app
                            allClients <- getAllClients app nickNameV
                            mapM_ (\conn -> 
                                    mapM_ (\cs -> 
                                            writeTChan (writeChan conn) 
                                                (UserJoined.userLoggedIn (ClientState.nickName cs)) 
                                            ) allClients
                                    ) currentClientState                            
                            mapM_ (\text -> 
                                        mapM_ (\cs -> 
                                                    writeTChan (writeChan cs) text) 
                                                    currentClientState
                                        ) messageHistory
            return "Threads Exiting"

handleDisconnects :: App -> WSConn.Connection -> T.Text -> ConnectionException -> IO ()
handleDisconnects app connection nickN (CloseRequest a b) = do 
            Logger.errorM iModuleName $ T.unpack $  
                ("Bye nickName " :: T.Text) `mappend` nickN
            atomically $ do 
                deleteConnection app nickN
                restOfUs <- getAllClients app nickN
                case restOfUs of 
                    x  : _ -> do  
                        mapM_ (\cs -> 
                                writeTChan(writeChan cs) $ 
                                    UserJoined.userLeft nickN )restOfUs
                    [] -> return ()
            
handleDisconnects app connecction nickN c = do 
    Logger.errorM iModuleName $ T.unpack $ 
                    ("Bye nickname " :: T.Text) `mappend` nickN 
                            `mappend` (T.pack $ show c)
    atomically $ do 
        deleteConnection app nickN 
        restOfUs <- getAllClients app nickN
        case restOfUs of 
            x  : _ -> do  
                mapM_ (\cs -> 
                        writeTChan(writeChan cs) $ 
                            UserJoined.userLeft nickN )restOfUs
            [] -> return ()

readerThread :: App -> T.Text -> Bool -> IO ()
readerThread app nickN terminate = do
    if (terminate == True) 
        then do 
            Logger.infoM iModuleName "Reader thread exiting" 
            return () 
    else do 
        Logger.infoM iModuleName "Waiting for messages..."
        (conn , textData) <- atomically $ do
                clientStates <- getClientState nickN app 
                case clientStates  of 
                    clientState : _ -> do 
                        textData <- readTChan (readChan clientState)                        
                        return (Just $ connection clientState, textData)
                    [] -> return (Nothing, "")
        x <- case conn of 
            Just connection -> do 
                            _ <- WSConn.sendTextData (connection) textData `catch` 
                                    (\h@(CloseRequest e f)-> do 
                                                handleDisconnects app 
                                                    connection nickN h
                                                readerThread app nickN True)
                            liftIO $ Logger.debugM iModuleName 
                                        $ "Wrote " `mappend` 
                                        (show $ T.take 150 textData) `mappend` (show conn)
                            readerThread app nickN terminate
            Nothing -> readerThread app nickN True -- Dont Terminate the thread.  
        return x

jobReaderThread :: App -> T.Text -> Bool -> IO ()
jobReaderThread app nickN terminate = 
    if(terminate == True) then do 
        Logger.infoM iModuleName "Job reader thread exiting."
        return ()
    else do
        Logger.infoM iModuleName "Waiting for jobs..."
        (conn , value) <- atomically $ do
                clientStates <- getClientState nickN app 
                case clientStates  of 
                    clientState : _ -> do 
                        textData <- readTChan (jobReadChan clientState)
                        return (Just $ connection clientState, textData)
                    [] -> return (Nothing, "Client state doesnt exist")
        Logger.infoM iModuleName ("Reading a job " ++ (show value))
        case conn of 
            Just connection -> do
                        (replyType, text) <- 
                            (ProjectWorkbench.executeWorkbench value)
                                `catch` (\ x@(SomeException e) -> return (Reply, "Exception in job " :: T.Text))
                        _ <- WSConn.sendTextData (connection) text `catch` 
                                (\h@(CloseRequest e f)-> do
                                            Logger.errorM iModuleName $ 
                                                    "Shutting down job reader thread. " 
                                                    `mappend` (show e) 
                                                    `mappend` " for " 
                                                    `mappend` (show f)
                                            handleDisconnects app 
                                                    connection nickN h)
                        jobReaderThread app nickN terminate
                        Logger.infoM iModuleName "Finished processing job " 
            Nothing -> jobReaderThread app nickN True  
        Logger.infoM iModuleName "Finished processing job" 


{-- | Market data thread polls for the market data values for all the symbols
    | across all the portfolios for the user.
 --}

{-- The main processing loop for incoming commands.--}
writerThread :: App -> WSConn.Connection -> T.Text -> Bool -> IO ()
writerThread app connection nickName terminate = do
    Logger.debugM iModuleName $ 
        (show connection) ++ "->" ++  (T.unpack nickName)
    if (terminate == True) 
        then do 
            Logger.infoM iModuleName "Writer thread exiting."
            return () 
        else do 
            traceEventIO "Before reading connection data"
            allClients <- atomically $ countAllClients app 
            allClientIds <- atomically $ getAllClientIdentifiers app
            msg <- WSConn.receiveData connection `catch` 
                (\h -> 
                    case h of 
                        (CloseRequest a b ) -> 
                            do 
                            _ <- handleDisconnects app connection nickName h
                            Logger.errorM iModuleName  "Close request received"                        
                            return . T.pack 
                                    $ "Close request received " <> (show a) <> (show b)
                        _ -> do 
                            handleDisconnects app connection nickName h
                            Logger.errorM iModuleName $ "Unknown exception " `mappend` (show h)
                            liftIO $ WSConn.sendClose connection ("Nick name processing error. Bye" :: T.Text)
                            writerThread app connection nickName True -- close this thread..                 
                            return $ "Bailing out.."
                )
            error1  <- liftIO $ runErrorT $ runP $ nickName2 $ incomingDictionary (msg :: T.Text)
            case error1 of 
                Left driverError -> do 
                        Logger.errorM iModuleName ("Driver error " ++ (show msg))
                        liftIO $ WSConn.sendClose connection (T.pack $ show msg)
                        return ()
                Right nickName -> do
                        Logger.debugM iModuleName $ "Process incoming message " <> (show msg)
                        (dest, x) <- liftIO $ processIncomingMessage app connection nickName 
                                                    $ incomingDictionary msg                    
                        liftIO $ Logger.debugM iModuleName ("Destination " ++ (show dest))
                        atomically $ do 
                                        clientStates <- case dest of 
                                            Broadcast -> getAllClients app nickName 
                                            PrivateMessage t ->
                                                getClientState t app
                                            _ ->
                                                getClientState nickName app                                        
                                        mapM_ (\cs -> writeTChan (writeChan cs) (x)) clientStates
                        WSConn.sendPing connection ("ping" :: T.Text)
                        writerThread app connection nickName terminate

postHomeR :: Handler ()
postHomeR = do 
    incomingRequest <- (requireJsonBody :: Handler Value)
    liftIO $ Logger.debugM iModuleName ("Incoming request" <> (show incomingRequest))
    return ()
getHomeR :: Handler String
getHomeR = do
    request <- waiRequest
    liftIO $ Logger.infoM iModuleName 
                $ "Request " <> (show request)
    webSockets ccarApp
    return $ show request


staleClientInterval :: IO Integer 
staleClientInterval = getEnv("STALE_CLIENT_INTERVAL") >>= \x -> return 
            $ toInteger . parse_time_interval $ x

-- TODO: Fix this
mkClientInterval :: Integer -> NominalDiffTime 
mkClientInterval _ = 20::NominalDiffTime 
-- TODO: use parsec to return the stale client interval.
cleanupStaleConnections :: App -> IO ()
cleanupStaleConnections app = loop 
    where loop = do 
                clientInterval <- staleClientInterval
                Logger.debugM "CCAR " $ "Using " <> (show clientInterval)
                threadDelay (fromIntegral clientInterval) -- Active connection for 30 seconds.
                Logger.debugM  "CCAR" $ "Waiting for stale connections-----" -- time is in the logger.
                -- Stale client is broken now.
                staleClients <- 
                    getCurrentTime >>= \x -> 
                            atomically $ getStaleClients app (mkClientInterval clientInterval) x
                mapM_ (\x -> do 
                        Logger.infoM "CCAR" $ "Deleting client " ++ (show x)
                        atomically $ deleteConnection app (ClientState.nickName x)
                        ) staleClients
                Logger.debugM "CCAR" "Stale connections cleaned"
                loop


driver :: IO ()
driver = do
    sH <- openFile "debug.log" WriteMode
    hSetBuffering sH $ BlockBuffering $ Just 4096
    h <- SimpleLogger.streamHandler sH Log.DEBUG
    lh <- return $ setFormatter h (simpleLogFormatter "[$time : $loggername : $prio : $tid] $msg")
--    s <- SimpleLogger.streamHandler stderr Log.ERROR
    _ <- Logger.updateGlobalLogger "CCAR" $ Logger.setLevel 
                                        Log.DEBUG . setHandlers[lh]
    
    _ <- Logger.updateGlobalLogger "CCAR.DBUtils" $ Logger.setLevel 
                                            Log.INFO . setHandlers[lh]
    _ <- Logger.updateGlobalLogger "CCAR.Analytics.OptionAnalytics" $ Logger.setLevel 
                                        Log.INFO . setHandlers[lh]                                        
    Logger.debugM "CCAR" "Starting yesod.."

    connStr <- getConnectionString
    poolSize <- getPoolSize
    runStderrLoggingT $ withPostgresqlPool connStr poolSize $ \pool ->
        liftIO $ do
            flip runSqlPersistMPool pool $ do
                runMigration ccarModel
    b <- A.async $ EquityAnalytics.startup
    c <- A.async $ Country.startup
    t <- A.async $ TradierApi.startup
    u <- A.async $ EquityBenchmark.startup
    chan <- atomically newBroadcastTChan
--    static@(Static settings) <- static "static"
    nickNameMap <- newTVarIO $ IMap.empty
    let app = App chan nickNameMap
    v <- A.async $ cleanupStaleConnections app
    warp 3000 app 



-- Needs to go somewhere other than the driver.
processActivePortfolio :: T.Text -> App -> Value -> IO (DestinationType, Either ApplicationError PortfolioT) 
processActivePortfolio nickName app (Object a) = do 
    let r = (parse parseJSON (Object a) :: Result ActivePortfolio)
    case r of 
        Success x -> do 
                let p = runAP x
                Logger.debugM "CCAR" ("Processing updating active portfolio " ++ show p)
                atomically $ updateActivePortfolio nickName app p 
                aP <- atomically $ getActivePortfolio nickName app
                Logger.debugM "CCAR" ("Getting the active portfolio " ++ (show aP) )
                return(CCAR.Main.GroupCommunication.Reply, Right p)
        Error e -> 
                return (CCAR.Main.GroupCommunication.Reply, Left $ appError e)

processActivePortfolio nickName app _ = return (CCAR.Main.GroupCommunication.Reply, Left $ appError $ ("Not an object" :: String))


