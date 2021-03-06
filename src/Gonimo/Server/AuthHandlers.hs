{-# OPTIONS_GHC -fno-warn-unused-imports #-}
module Gonimo.Server.AuthHandlers where

import           Control.Concurrent.STM              (STM, TVar, readTVar)
import           Control.Lens
import           Control.Monad
import           Control.Monad.Freer                 (Eff)
import           Control.Monad                       (guard)
import           Control.Monad.Freer.Reader          (ask)
import           Control.Monad.STM.Class             (liftSTM)
import           Control.Monad.Trans.Class           (lift)
import           Control.Monad.Trans.Maybe           (MaybeT(..), runMaybeT)
import           Utils.Control.Monad.Trans.Maybe     (maybeT)
import qualified Data.Map.Strict                     as M
import           Data.Proxy                          (Proxy (..))
import qualified Data.Set                            as S
import           Data.Text                           (Text)
import           Database.Persist                    (Entity (..))
import qualified Gonimo.Database.Effects             as Db
import           Gonimo.Database.Effects.Servant
import           Gonimo.Server.Auth                  as Auth
import           Gonimo.Server.AuthHandlers.Internal
import           Gonimo.Server.DbEntities
import           Gonimo.Server.Effects
import           Gonimo.Server.EmailInvitation
import           Gonimo.Server.Error
import           Gonimo.Server.State
import           Gonimo.Server.Types
import           Gonimo.WebAPI                       (ReceiveChannelR,
                                                      ReceiveSocketR)
import           Gonimo.WebAPI.Types                 (InvitationInfo (..),
                                                      InvitationReply (..))
import qualified Gonimo.WebAPI.Types                 as Client
import           Servant.API                         ((:>))
import           Servant.Server                      (ServantErr (..), err400,
                                                      err403)
import           Servant.Subscriber                  (Event (ModifyEvent))

createInvitation :: AuthServerConstraint r => FamilyId -> Eff r (InvitationId, Invitation)
createInvitation fid = do
  authorizeAuthData $ isFamilyMember fid
  now <- getCurrentTime
  isecret <- generateSecret
  -- family <- getFamily fid  -- defined but not used (yet).
  senderId' <- authView $ clientEntity.to entityKey
  let inv = Invitation {
    invitationSecret = isecret
    , invitationFamilyId = fid
    , invitationCreated = now
    , invitationDelivery = OtherDelivery
    , invitationSenderId = senderId'
    , invitationReceiverId = Nothing
  }
  iid <- runDb $ Db.insert inv
  return (iid, inv)


putInvitationInfo :: AuthServerConstraint r => Secret -> Eff r InvitationInfo
putInvitationInfo invSecret = do
  aid <- authView $ accountEntity . to entityKey
  runDb $ do
    Entity invId inv <- getBy404 $ SecretInvitation invSecret
    guardWithM InvitationAlreadyClaimed
      $ case invitationReceiverId inv of
        Nothing -> do
          Db.replace invId $ inv { invitationReceiverId = Just aid }
          return True
        Just receiverId' -> return $ receiverId' == aid
    invFamily  <- get404   $ invitationFamilyId inv
    invClient  <- get404   $ invitationSenderId inv
    mInvUser   <- Db.getBy $ AccountIdUser (clientAccountId invClient)
    return InvitationInfo
                { invitationInfoFamily = familyName invFamily
                , invitationInfoSendingClient = clientName invClient
                , invitationInfoSendingUser = userLogin . entityVal <$> mInvUser
                }

answerInvitation :: AuthServerConstraint r => Secret -> InvitationReply -> Eff r ()
answerInvitation invSecret reply = do
  authData <- ask
  let aid = authData ^. accountEntity . to entityKey
  now <- getCurrentTime
  inv <- runDb $ do
    Entity iid inv <- getBy404 (SecretInvitation invSecret)
    guardWith InvitationAlreadyClaimed
      $ case invitationReceiverId inv of
          Nothing -> True
          Just receiverId' -> receiverId' == aid
    Db.delete iid
    return inv
  runDb $ do -- Separate transaction - we want the invitation to be deleted now!
    when (reply == InvitationAccept ) $ do
      guardWith AlreadyFamilyMember
        $ not $ isFamilyMember (invitationFamilyId inv) authData
      Db.insert_  FamilyAccount {
          familyAccountAccountId = aid
        , familyAccountFamilyId = invitationFamilyId inv
        , familyAccountJoined = now
        , familyAccountInvitedBy = Just (invitationDelivery inv)
        }

sendInvitation :: AuthServerConstraint r => Client.SendInvitation -> Eff r ()
sendInvitation (Client.SendInvitation iid d@(EmailInvitation email)) = do
  authData <- ask -- Only allowed if user is member of the inviting family!
  (inv, family) <- runDb $ do
    inv <- get404 iid
    authorize (isFamilyMember (invitationFamilyId inv)) authData
    let newInv = inv {
      invitationDelivery = d
    }
    Db.replace iid newInv
    family <- get404 (invitationFamilyId inv)
    return (newInv, family)
  sendEmail $ makeInvitationEmail inv email (familyName family)
sendInvitation (Client.SendInvitation _ OtherDelivery) =
  throwServant err400 {
    errReasonPhrase = "OtherDelivery means - you took care of the delivery. How am I supposed to perform an 'OtherDelivery'?"
  }


createFamily :: AuthServerConstraint r =>  FamilyName -> Eff r FamilyId
createFamily n = do
  -- no authorization: - any valid user can create a family.
  now <- getCurrentTime
  uid <- askAccountId
  runDb $ do
    fid <- Db.insert Family {
        familyName = n
      , familyCreated = now
      , familyLastAccessed = now
    }
    Db.insert_ FamilyAccount {
      familyAccountAccountId = uid
      , familyAccountFamilyId = fid
      , familyAccountJoined = now
      , familyAccountInvitedBy = Nothing
    }
    return fid

createChannel :: AuthServerConstraint r
              => FamilyId -> ClientId -> ClientId -> Eff r Secret
createChannel familyId toId fromId = do
  -- is it a good idea to expose the db-id in the route - people know how to use
  -- a packet sniffer

  secret <- generateSecret
  authorizedPut (putSecret secret fromId toId) familyId fromId toId

  notify ModifyEvent endpoint (\f -> f familyId toId)
  return secret
 where
   endpoint :: Proxy ("socket" :> ReceiveSocketR)
   endpoint = Proxy


receiveSocket :: AuthServerConstraint r
               => FamilyId -> ClientId -> Eff r (ClientId, Secret)
-- | in this request @to@ is the one receiving the secret
receiveSocket familyId toId =
  authorizedRecieve'(receiveSecret toId) familyId toId

putChannel :: AuthServerConstraint r
           => FamilyId -> ClientId -> ClientId -> Secret -> Text -> Eff r ()
putChannel familyId fromId toId token txt = do

  authorizedPut (putData txt token fromId) familyId fromId toId 

  notify ModifyEvent endpoint (\f -> f familyId fromId toId token)
  where
   endpoint :: Proxy ("socket" :> ReceiveChannelR)
   endpoint = Proxy


receiveChannel :: AuthServerConstraint r
               => FamilyId -> ClientId -> ClientId -> Secret -> Eff r Text
receiveChannel familyId fromId toId token =
  authorizeJust (\(fromId',t) -> do guard (fromId == fromId'); return t)
    =<< authorizedRecieve (receieveData token) familyId fromId toId

-- The following stuff should go somewhere else someday (e.g. to paradise):

-- | Get the family of the requesting device.
--
--   error 404 if not found.
--   TODO: Get this from in memory data structure when available.
getFamily :: ServerConstraint r => FamilyId -> Eff r Family
getFamily fid = runDb $ get404 fid
