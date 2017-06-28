module CCAR.Main.Application
    (App(..)
    , getClientState
    , updateClientState
    , updateActivePortfolio)
where

import Data.Text as T 
import Data.Map as Map
import CCAR.Main.GroupCommunication as GroupCommunication
import Control.Concurrent.STM.Lifted
import Control.Distributed.Process
import Data.Time
import CCAR.Data.ClientState
import Control.Monad.Trans.Reader
import CCAR.Model.PortfolioT
import Control.Monad.Trans

type NickName = T.Text

-- the broadcast channel for the application.
-- todo : explore changing this to a tighter abstraction.   
data App = App { chan :: TChan T.Text
                , proxy :: TChan (Process())
                , connectionsMap :: TVar (Map ProcessId Int)
                , nickNameMap :: ClientMap}


type ClientMap = GroupCommunication.ClientIdentifierMap



-- Convert a result of a map to a list
getClientState :: T.Text -> App -> STM [ClientState]
getClientState nickName app@(App a _ _ c) = do
        nMap <- readTVar c
        return $ Map.elems $ filterWithKey(\k _ -> k ==  nickName) nMap


updateClientState :: T.Text -> App -> UTCTime -> STM ()
updateClientState nickName app@(App a _ _ c) currentTime = do 
    nMap <- readTVar c 
    if Map.member nickName nMap then do 
        nClientState <- return $ nMap ! nickName
        x <- writeTVar (nickNameMap app) (Map.insert nickName (nClientState {lastUpdateTime = currentTime}) nMap)
        return ()
    else
        return ()

updateActivePortfolio :: T.Text -> App -> PortfolioT -> STM ()
updateActivePortfolio nickName app@(App a _ _ c) p = do 
    nMap <- readTVar c 
    if Map.member nickName nMap then do  
        nClientState <- return $ nMap ! nickName
        a <- return $ Just $ makeActivePortfolio p
        writeTVar (nickNameMap app)
                (Map.insert nickName (nClientState {activePortfolio = a }) nMap)
        return ()
    else
        return ()

