{-# LANGUAGE CPP #-}
module Main where

import           Control.Concurrent.STM            (atomically)
import           Control.Concurrent.STM.TVar
import           Control.Monad.Logger
import qualified Data.ByteString.Char8             as S8
import qualified Data.Map.Strict                   as Map
import           Database.Persist.Sqlite
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Middleware.Static
import           Servant.Subscriber
import           System.IO                         (Handle, stderr)
import           System.Log.FastLogger             (fromLogStr)

import           Gonimo.Server
import           Gonimo.Server.DbEntities
import           Gonimo.Server.InitDb
#ifdef DEVELOPMENT
import           Gonimo.Server.Effects.Development
#else
import           Gonimo.Server.Effects.Production
#endif
import           Database.Persist.Postgresql

logHandle :: Handle
logHandle = stderr

devMain :: IO ()
devMain = do
  let subscriberPath = "subscriber"
  subscriber' <- atomically $ makeSubscriber subscriberPath runStderrLoggingT
  pool        <- runLoggingT (createSqlitePool "testdb" 1) doLogging
  families    <- newTVarIO Map.empty
  flip runSqlPool pool $ do
    runMigration migrateAll
    initDb
  let config = Config {
    configPool = pool
  , configLog  = logToHandle logHandle
  , state      = families
  , subscriber = subscriber'
  }
  run 8081 $ addDevServer $ serveSubscriber subscriber' (getServer config)

prodMain :: IO ()
prodMain = do
  let subscriberPath = "subscriber"
  subscriber' <- atomically $ makeSubscriber subscriberPath runStderrLoggingT
  -- empty connection string means settings are fetched from env.
  pool        <- runLoggingT (createPostgresqlPool "" 10) doLogging
  families    <- newTVarIO Map.empty
  flip runSqlPool pool $ do
    runMigration migrateAll
    initDb
  let config = Config {
    configPool = pool
  , configLog  = logToHandle logHandle
  , state      = families
  , subscriber = subscriber'
  }
  run 8081 $ serveSubscriber subscriber' (getServer config)

main :: IO ()
#ifdef DEVELOPMENT
main = devMain
#else
main = prodMain
#endif

addDevServer :: Application -> Application
addDevServer = staticPolicy $ addBase "../gonimo-front/dist" <|> addSlash


doLogging :: Loc -> LogSource -> LogLevel -> LogStr -> IO ()
doLogging = logToHandle logHandle

logToHandle :: Handle -> Loc -> LogSource -> LogLevel -> LogStr -> IO ()
logToHandle h loc src level msg = S8.hPutStr h ls
  where ls = logHandleBS loc src level msg

logHandleBS :: Loc -> LogSource -> LogLevel -> LogStr -> S8.ByteString
logHandleBS a b c d = fromLogStr $ defaultLogStr a b c d

