{-# LANGUAGE GADTs #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-- Freer extensible effects for database access, based on persistent types. --}
module Gonimo.Database.Effects where

import           Control.Exception.Base        (SomeException)
import           Control.Monad.Freer           (Eff, Member, send)
import           Control.Monad.Freer.Exception (Exc (..), throwError)


import           Database.Persist              (Entity, Filter,
                                                PersistEntity (..),
                                                PersistQuery, SelectOpt)


-- Type synonym for constraints on Database API functions, requires ConstraintKinds language extension:
type FullDbConstraint backend a r = ( DbConstraint backend r
                                    , PersistEntity a, backend ~ PersistEntityBackend a)

type DbConstraint backend r = (Member (Database backend) r , Member (Exc SomeException) r)


-- Tidy up the following Database definition
type EDatabase backend a =  Database backend (Either SomeException a)


data Database backend v where
  Insert     :: (backend ~ PersistEntityBackend a, PersistEntity a) => a -> EDatabase backend (Key a)
  Insert_    :: (backend ~ PersistEntityBackend a, PersistEntity a) => a -> EDatabase backend ()
  Replace    :: (backend ~ PersistEntityBackend a, PersistEntity a) => Key a -> a -> EDatabase backend ()
  Delete     :: (backend ~ PersistEntityBackend a, PersistEntity a) => Key a -> EDatabase backend ()
  DeleteBy   :: (backend ~ PersistEntityBackend a, PersistEntity a) => Unique a -> EDatabase backend ()
  Get        :: (backend ~ PersistEntityBackend a, PersistEntity a) => Key a -> EDatabase backend (Maybe a)
  GetBy      :: (backend ~ PersistEntityBackend a, PersistEntity a) => Unique a -> EDatabase backend (Maybe (Entity a))
  SelectList :: (backend ~ PersistEntityBackend a, PersistQuery backend, PersistEntity a) => [Filter a] -> [SelectOpt a] -> EDatabase backend [Entity a]

insert :: FullDbConstraint backend a r => a -> Eff r (Key a)
insert = sendDb . Insert

insert_ :: FullDbConstraint backend a r => a -> Eff r ()
insert_ = sendDb . Insert_

replace :: FullDbConstraint backend a r => Key a -> a -> Eff r ()
replace k v = sendDb $ Replace k v

get :: FullDbConstraint backend a r => Key a -> Eff r (Maybe a)
get = sendDb . Get

delete :: FullDbConstraint backend a r => Key a -> Eff r ()
delete = sendDb . Delete

deleteBy :: FullDbConstraint backend a r => Unique a -> Eff r ()
deleteBy = sendDb . DeleteBy
  
getBy :: FullDbConstraint backend a r => Unique a -> Eff r (Maybe (Entity a))
getBy = sendDb . GetBy

selectList :: (FullDbConstraint backend a r, PersistQuery backend) => [Filter a] -> [SelectOpt a] -> Eff r [Entity a]
selectList f s = sendDb $ SelectList f s

-- Send a server operation, that is an operation that might fail:
sendDb :: (Member (Database backend) r, Member (Exc SomeException) r) => EDatabase backend a -> Eff r a
sendDb op = do
  r <- send op
  case r of
    Left e -> throwError e
    Right v -> return v
