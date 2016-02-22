{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module Gonimo.Server.DbEntities where


import Gonimo.Database.Persist.TH
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Gonimo.Server.DbTypes
import Data.Aeson.Types (FromJSON, ToJSON(..), defaultOptions, genericToEncoding, genericToJSON)

mkPersist sqlSettings [persistLowerCase|
  Account
    secret Secret
    created UTCTime
    lastAccessed UTCTime
    email Text Maybe
    phone Text Maybe
    password Text Maybe
    SecretAccount secret

  Family
    created UTCTime
    lastAccessed UTCTime
    creatorId AccountId

  FamilyAccount
    accountId AccountId
    familyId  FamilyId
    joined UTCTime
    invitedBy InvitationDelivery Maybe
    FamilyMember accountId familyId

  Invitation
    secret Secret
    familyId FamilyId
    created UTCTime
    delivery InvitationDelivery
    SecretInvitation secret
    deriving Show Generic
|]

instance FromJSON Invitation
instance ToJSON Invitation where
  toJSON = genericToJSON defaultOptions
  toEncoding = genericToEncoding defaultOptions