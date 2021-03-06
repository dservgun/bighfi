    {--License: license.txt --}
module CCAR.Main.Util
    (serialize, parseDate 
        , parse_time_interval
        , parse_float
        , getPastDate, getUTCTime
        , timeDiffs
        , processError
        , lastFridayOfMonth)
where
import Data.Text as T  hiding(foldl, foldr)
import Data.Aeson as J
import Control.Applicative as Appl
import Data.Aeson.Encode as En
import Data.Aeson.Types as AeTypes(Result(..), parse)
import Data.Text.Lazy.Encoding as E
import Data.ByteString.Char8 as BS
import Data.Time.Calendar.MonthDay
import Data.Time.Calendar.WeekDate
import Data.Time.Calendar.OrdinalDate
import Data.Text.Lazy as L hiding(foldl, foldr)
import System.Locale as Loc 
import Data.Time
import Data.Time.Clock
import Network.HTTP.Client as HttpClient
import Data.Conduit
import Data.Conduit.Lift
import Control.Monad.State
import Control.Monad
import Numeric
import Debug.Trace
import Text.ParserCombinators.Parsec as Parsec
import GHC.Real
import Control.Applicative
import Control.Monad.State as State (State, get, put, modify, runState, execState, evalState)

serialize :: (ToJSON a) => a -> T.Text 
serialize  = L.toStrict . E.decodeUtf8 . En.encode  


getPastDate anInteger = \x -> return $ UTCTime (utctDay x) (neg anInteger) 
    where 
        neg x
            | x >= 0 = (-1) * x 
            | x < 0  = x

parseDate (Just aDate) = parseTime Loc.defaultTimeLocale (Loc.rfc822DateFormat) (aDate)



{--| Reads intervals in millis |--}  
parse_time_interval :: String -> Int
parse_time_interval input = 
    case Parsec.parse parse_time_interval1 ("Unknown") input of 
        Right x -> x 
        Left _  -> 10000 -- default time interval



parse_time_interval1 = do 
    s1 <- getInput
    r <- case readSigned readDec s1 of 
        [(n, s')] -> n <$ setInput s'
        _         -> Control.Applicative.empty  
    spaces
    time_interval <- many1 alphaNum
    i <- case time_interval of 
        "millis" ->  return 1000
        "seconds" -> return $ 10 ^ 6 
        "minutes" -> return $ 60 * 10 ^ 6
    return (r * i)



p_f = do 
    s <- getInput
    case readSigned readFloat s of 
        [(n, s')] -> n <$ setInput s'
        _         -> Control.Applicative.empty 
parse_float input = 
    case Parsec.parse p_f ("Unable to parse input " ++ (input))  input of 
        Right x -> x 
        Left _ -> 0.0

duplicate x = (x, x)

{--| Convert a simple text date to utc time.--}
getUTCTime :: T.Text -> Maybe UTCTime
getUTCTime startDate = parseTime defaultTimeLocale (dateFmt defaultTimeLocale) (T.unpack startDate)


processError :: Maybe a -> T.Text -> Either T.Text a 
processError Nothing msg =  Left msg
processError (Just x) _ =  Right x 


timeDiffs :: UTCTime -> UTCTime -> NominalDiffTime
timeDiffs currentTime lastUpdateTime =  
                            trace ("current time " ++ show currentTime ++ " last update time " ++ show lastUpdateTime)
                            (diffUTCTime 
                                currentTime
                                lastUpdateTime)

testTimeDiffs = do 
    t1 <- getCurrentTime
    nom <- return (20 :: NominalDiffTime)
    t2 <- return (addUTCTime nom t1)
    x <- return $ timeDiffs t2 t1
    return (x >= nom)

isFriday day =  
        case sundayStartWeek day of
            (_, 5) -> True
            _      -> False

-- Return the last Friday of a month.
lastFridayOfMonth n = do 
    x <- getCurrentTime >>= \l -> return $ utctDay l
    (yy, m, d) <- return $ toGregorian x
    -- Compute the number of days
    y <- Control.Monad.foldM (\a b -> 
                return $ 
                    a + (gregorianMonthLength yy (m + b)) - d) -- days to subtract
                0 [0..n]
    remDays <- Control.Monad.mapM (\x1 -> return $ addDays (toInteger x1) x) [0..y] -- calendar addition.
    fridays <- Control.Monad.filterM (\d -> return $ isFriday d) remDays
    rev <- Prelude.reverse `liftM` (return fridays)
    case rev of 
        h:t -> return $ BS.pack $ show h 
        [] -> return $ BS.pack $ ""    