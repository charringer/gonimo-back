module Gonimo.Server.Effects.TestServer (
  runExceptionServer
  , Config(..)
  , ServerEffects ) where


import           Control.Exception.Base (try, throwIO, fromException, SomeException)
import           Control.Monad.Freer.Exception (Exc(..), runError)
import           Control.Monad.Freer.Internal (Eff(..), Arrs, decomp, qApp)
import           Control.Monad.Logger (Loc, LogLevel, LogSource, LogStr, ToLogStr(..))
import           Data.Bifunctor (first)
import           Data.Monoid ((<>))
import           Data.Pool (Pool)

import           Database.Persist.Sql (SqlBackend, runSqlPool)
import qualified Gonimo.Database.Effects as Db
import           Gonimo.Database.Effects.PersistDatabase (runExceptionDatabase)
import           Gonimo.Server.Effects.Internal
import           Network.Mail.SMTP (sendMail)
import Control.Monad.Trans.Reader (ReaderT)
import Crypto.Random (SystemRandom, genBytes)
import Data.Time.Clock (getCurrentTime)
import Data.Maybe (fromMaybe)
import Control.Monad.Trans.Class (lift)
import Control.Monad ((<=<))

type DbPool = Pool SqlBackend
type LoggingFunction = Loc -> LogSource -> LogLevel -> LogStr -> IO ()

data Config = Config {
  configPool :: DbPool
  ,  configLog :: LoggingFunction
  , configRandGen :: SystemRandom
  }


runExceptionServer :: Config -> Eff (Exc SomeException ': '[Server]) w  -> IO (Either SomeException w)
runExceptionServer c = runServer c . runError

runServer :: forall w . Config -> Eff '[Server] (Either SomeException w) -> IO (Either SomeException w)
runServer _ (Val v) = return v
runServer c (E u' q) = case decomp u' of
  Right (SendEmail mail)           -> execIO c q $ sendMail "localhost" mail
  Right (LogMessage loc ls ll msg) -> execIO c q $ doLog loc ls ll (toLogStr msg)
  Right (GenRandomBytes l)         -> let (res, newC) = doGen l
                                      in runServer newC . qApp q $ res
  Right GetCurrentTime             -> execIO c q getCurrentTime

  Right (RunDb trans)              -> runDatabaseServerIO pool trans >>= runServer c . qApp q
  Left  _                          -> error impossibleMessage
  where
    pool = configPool c
    doLog = configLog c
    gen = configRandGen c
    -- runLogger loggerT = runLoggingT loggerT doLog
    doGen l = case genBytes l gen of
      Left e              -> (Left (toException e), c)
      Right (res, newGen) -> (Right res, c { configRandGen = newGen })



-- We throw exceptions instead of using Either, because only in this case, are database transactions rolled back.
runDatabaseServer :: forall w . Eff (Exc Db.DbException ': '[Db.Database SqlBackend]) w
                     -> ReaderT SqlBackend IO w
runDatabaseServer = throwExceptions <=< runExceptionDatabase
  where
    -- Needed to have runSqlPool roll back the transaction:
    throwExceptions :: Either SomeException a -> ReaderT SqlBackend IO a
    throwExceptions (Left e)  = lift $ throwIO e
    throwExceptions (Right v) = return v

runDatabaseServerIO :: forall w . Pool SqlBackend
                       -> Eff (Exc Db.DbException ': '[Db.Database SqlBackend]) w
                       -> IO (Either SomeException w)
runDatabaseServerIO pool = try . flip runSqlPool pool . runDatabaseServer

execIO :: Config
          -> Arrs '[Server] (Either SomeException b) (Either SomeException w)
          -> IO b
          -> IO (Either SomeException w)
execIO c q action = serverTry action >>= runServer c . qApp q

serverTry :: IO a -> IO (Either SomeException a)
serverTry op = first SystemException <$> try op


impossibleMessage :: String
impossibleMessage =
  "This cannot happen. Really! If you see this message, then, well - the impossible happened!\n"
  <> "Really this can not be.\n\nAre you really sure you are seeing this?"
