{-# LANGUAGE DeriveDataTypeable #-}
module Scyther.Equalities (
-- * Single Equalities
    TIDEq
  , TIDRoleEq
  , RoleEq
  , AgentEqRHS
  , AgentEq
  , AVarEq
  , MVarEq
  , MsgEq
  , AnyEq(..)

  , agentEqToMsgEq
  , mvarEqToMsgEq

-- * Compound Equalities
  , Equalities

  -- ** Construction
  , empty
  , solve
  , trimTIDEqs
  , trimAgentEqs

  -- ** Destruction
  , getTIDEqs
  , getTIDRoleEqs
  , getAgentEqs
  , getAVarEqs
  , getMVarEqs
  , getPostEqs
  , toAnyEqs
  , anyEqTIDs

  -- ** Substitution
  , substTID
  , substLocalId
  , substAVar
  , substMVar
  , substAgentId
  , substAgentEqRHS
  , substMsg
  , substAnyEq

  -- ** Additional Queries
  , threadRole
  , maxMappedTID
  , maxMappedAgentId
  , reflexive
  , null

-- * Mapping Logical Variables
  , Mapping(..)
  , emptyMapping
  , mkMapping
  , addTIDMapping
  , addAgentIdMapping
  , addTIDRoleMapping
  , deleteTIDMapping
  , deleteAgentIdMapping

-- * Pretty Printing
  , sptAnyEq
) where

import Prelude hiding (null)

import qualified Data.Map       as M
import qualified Data.UnionFind as U
import Data.Data

import Control.Arrow ( (***) )
import Control.Monad

import Text.Isar

import Scyther.Protocol
import Scyther.Message


------------------------------------------------------------------------------
-- Equalities
------------------------------------------------------------------------------

-- | Equalities over thread identifers. 
--
-- Logically these are equalities between logical thread identifier variables.
type TIDEq   = (TID, TID)
type TIDEqs  = M.Map TID TID

-- | A thread to role assignment.
type TIDRoleEq  = (TID, Role)
type TIDRoleEqs = M.Map TID Role

-- | The role equalities serve a double function:
type RoleEq  = (Role, Role)

type AgentEqRHS = Either AgentId AVar
type AgentEq    = (AgentId, AgentEqRHS)

-- | Like role equalities, the agent equalities specify both quantification and
-- equalities. Recall that an agent id is a logical variable denoting some
-- agent name. Such an agent name is either equal to another agent id or the
-- content of an agent variable of a thread.
type AgentEqs = M.Map AgentId AgentEqRHS

-- | Equalities between different agent variables. 
--
-- We do not have to reason about equalities between an agent variable and some
-- other message because our semantics guarantees that agent variables are only
-- instantiated with agent names. Hence, they can only be equal to other agent
-- variables or message variables. In the latter case, we store the equality
-- the other way round; assigning the agent variable to the message variable.
type AVarEq  = (AVar, AVar)
type AVarEqs = M.Map AVar AVar

-- | Equalities between message variables and arbitrary messages.
type MVarEq  = (MVar, Message)
type MVarEqs = M.Map MVar Message

-- | Equalities between messages.
type MsgEq  = (Message, Message)
type MsgEqs = U.UnionFind Message 

-- | Some representable equality.
data AnyEq = 
    TIDEq     !TIDEq
  | TIDRoleEq !TIDRoleEq
  | RoleEq    !RoleEq
  | AgentEq   !AgentEq
  | AVarEq    !AVarEq
  | MVarEq    !MVarEq
  | MsgEq     !MsgEq
  deriving( Eq, Ord, Show, Data, Typeable )

-- | A conjunction of equality facts.
--
-- Invariants for a value @eqs = Equalities tideqs roleeqs avareqs mvareqs agnteqs@:
--
--   1. Domain and range normalized with respect to equalities. Note that this implies
--      substitution must always consider TID substitution first.
--
--        forall tid : ran(tideqs).     substTID eqs tid = tid
--        forall tid : dom(roleeqs).    substTID eqs tid = tid
--        forall (lid, lid') : avareqs. substLocalId eqs lid = lid 
--                                    & substAVar eqs lid' = lid'
--        forall (lid, m)    : mvareqs. substLocalId eqs lid = lid 
--                                    & substMsg eqs m = m
--        
--     TODO: Complete properties for Agent ID's
--
--        forall aid : dom(agnteqs).    substAgentId eqs aid = Just (Left aid)
--        forall  : dom(agnteqs).    substAgentId eqs aid = Just (Left aid)
--
--
--   2. Origin always greater than image for symmetric eqs.
--
--        forall (tid, tid') : tideqs.  tid > tid'
--        forall (lid, lid') : avareqs. lid > lid'
--
--   3. Range of message variable equalities normalized with respect to key inversion.
--
--        forall m : ran(mvareqs). normMsg m = m
--
--   4. All thread identifiers are in the domain of roleeqs.
--
--   5. All agent identifiers are in the domain of agnteqs.
--
--   6. No cycles.
--
data Equalities = Equalities {
    tidEqs  :: TIDEqs   -- ^ Thread identifier equalities.
  , roleEqs :: TIDRoleEqs  -- ^ Thread to role assignments.
  , avarEqs :: AVarEqs  -- ^ Equalities between agent variables.
  , mvarEqs :: MVarEqs  -- ^ Equalities between message variables and arbitrary messages.
  , agntEqs :: AgentEqs -- ^ Equalities between agent names and agent names or agent variables.
  , postEqs :: MsgEqs   -- ^ Postponed equalities that stem from equalities involving
                        -- bi-directional keys and cannot be solved without
                        -- splitting in their most general form @KShr a b = KShr c d@. We
                        -- try to exploit these postponed equalities after
                        -- every regular unification.
  }
  deriving( Eq, Ord, Show, Data, Typeable {-! NFData !-} )

-- | Empty equality premises.
empty :: Equalities
empty = Equalities M.empty M.empty M.empty M.empty M.empty U.empty

-- | True if no equalities are present.
null :: Equalities -> Bool
null = (==) empty

-- Substitution
---------------

-- NOTE: Here we exploit that range of equalities does not contain any
-- identifier from the domain.

-- | Substitute a thread identifier according to thread identifier equalities.
substTID :: Equalities -> TID -> TID
substTID eqs tid = M.findWithDefault tid tid (tidEqs eqs)

-- | Substitute a local identifier according to thread identifier equalities.
substLocalId :: Equalities -> LocalId -> LocalId
substLocalId eqs (LocalId (i, tid)) = (LocalId (i, substTID eqs tid))

-- | Substitute a local identifier belonging to an agent variable.
substAVar :: Equalities -> AVar -> AVar
substAVar eqs av = M.findWithDefault av' av' (avarEqs eqs)
  where av' = mapAVar (substLocalId eqs) av

-- | Substitute a local identifier belonging to a message variable.
substMVar :: Equalities -> MVar -> Message
substMVar eqs mv = M.findWithDefault (MMVar mv') mv' (mvarEqs eqs)
  where mv' = mapMVar (substLocalId eqs) mv

-- | Substitute an agent id representing an arbitrary agent name.
substAgentId :: Equalities -> AgentId -> AgentEqRHS
substAgentId eqs aid = M.findWithDefault (Left aid) aid (agntEqs eqs)

-- | Substitute the right-hand-side of an agent id equality.
substAgentEqRHS :: Equalities -> AgentEqRHS -> AgentEqRHS
substAgentEqRHS eqs = either (substAgentId eqs) (Right . substAVar eqs)

-- | Substitute message constituents according to equalities.
--
-- POST: Message normalized w.r.t. 'normMsg'.
substMsg :: Equalities -> Message -> Message
substMsg eqs = normMsg . go
  where
    go m@(MConst _)   = m
    go (MFresh fr)    = MFresh (mapFresh (substLocalId eqs) fr)
    go (MAVar av)     = MAVar (substAVar eqs av)
    go (MMVar mv)     = substMVar eqs mv
    go (MAgent aid)   = either MAgent MAVar (substAgentId eqs aid)
    go (MHash m)      = MHash (go m)
    go (MTup m1 m2)   = MTup (go m1) (go m2)
    go (MEnc m1 m2)   = MEnc (go m1) (go m2)
    go (MSymK m1 m2)  = MSymK (go m1) (go m2)
    go (MShrK m1 m2)  = 
        U.findWithDefault m' m' $ postEqs eqs 
      where
        m' = MShrK (go m1) (go m2)
    go (MAsymPK m)    = MAsymPK (go m)
    go (MAsymSK m)    = MAsymSK (go m)
    go (MInvKey m)    = MInvKey (go m)

-- | Substitute a thread id equalitiy.
substTIDEq :: Equalities -> TIDEq -> TIDEq
substTIDEq eqs = substTID eqs *** substTID eqs

-- | Substitute a thread id to role equality.
substTIDRoleEq :: Equalities -> TIDRoleEq -> AnyEq
substTIDRoleEq eqs (tid, role) = case threadRole tid' eqs of
    Just role' -> RoleEq    (role, role')
    Nothing    -> TIDRoleEq (tid', role)
  where
    tid' = substTID eqs tid

-- | Substitute an agent equality.
substAgentEq :: Equalities -> AgentEq -> MsgEq
substAgentEq eqs =
  substMsgEq eqs . agentEqToMsgEq

-- | Substitute an agent variable equality.
substAVarEq :: Equalities -> AVarEq -> AVarEq
substAVarEq eqs = substAVar eqs *** substAVar eqs

-- | Substitute a message variable equality.
substMVarEq :: Equalities -> MVarEq -> MsgEq
substMVarEq eqs = substMVar eqs *** substMsg eqs

-- | Substitute a message equality.
substMsgEq :: Equalities -> MsgEq -> MsgEq
substMsgEq eqs = substMsg eqs *** substMsg eqs

-- | Substitute both sides of a representable equality.
substAnyEq :: Equalities -> AnyEq -> AnyEq
substAnyEq eqs eq0 = case eq0 of
  TIDEq     eq -> TIDEq  $ substTIDEq     eqs eq
  TIDRoleEq eq ->          substTIDRoleEq eqs eq
  RoleEq    _  -> eq0
  AgentEq   eq -> MsgEq  $ substAgentEq   eqs eq
  AVarEq    eq -> AVarEq $ substAVarEq    eqs eq
  MVarEq    eq -> MsgEq  $ substMVarEq    eqs eq
  MsgEq     eq -> MsgEq  $ substMsgEq     eqs eq


-- Checking for reflexivity
---------------------------

-- | Convert an agent equality to a message equality.
agentEqToMsgEq :: AgentEq -> MsgEq
agentEqToMsgEq (aid, rhs) = (MAgent aid, either MAgent MAVar rhs)

-- | Convert a message variable equallity to a message equality.
mvarEqToMsgEq :: MVarEq -> MsgEq
mvarEqToMsgEq (v, m) = (MMVar v, m)

-- | Check if an equality is reflexive.
reflexive :: AnyEq -> Bool
reflexive eq0 = case eq0 of
  TIDEq     eq -> uncurry (==) eq
  TIDRoleEq _  -> False
  RoleEq    eq -> uncurry (==) eq
  AgentEq   eq -> reflexive . MsgEq $ agentEqToMsgEq eq
  AVarEq    eq -> uncurry (==) eq
  MVarEq    eq -> reflexive . MsgEq $ mvarEqToMsgEq eq
  MsgEq     eq -> uncurry (==) eq

-- Deconstruction
-----------------

-- | The list of thread identifier equalities.
getTIDEqs :: Equalities -> [TIDEq]
getTIDEqs = M.toList . tidEqs

-- | The list of role equalities.
getTIDRoleEqs :: Equalities -> [TIDRoleEq]
getTIDRoleEqs = M.toList . roleEqs

-- | The list of agent variable equalities.
getAgentEqs :: Equalities -> [AgentEq]
getAgentEqs = M.toList . agntEqs

-- | The list of agent variable equalities.
getAVarEqs :: Equalities -> [AVarEq]
getAVarEqs = M.toList . avarEqs

-- | The list of message variable equalities.
getMVarEqs :: Equalities -> [MVarEq]
getMVarEqs = M.toList . mvarEqs

-- | The list of postponed message equalities.
getPostEqs :: Equalities -> [MsgEq]
getPostEqs = U.toList . postEqs

-- | Convert a set of equalities ot the tuple with lists for each individual
-- equality type.
toLists :: Equalities -> ([TIDEq], [TIDRoleEq], [AgentEq], [AVarEq], [MVarEq], [MsgEq])
toLists eqs = 
  (getTIDEqs eqs, getTIDRoleEqs eqs, getAgentEqs eqs
  , getAVarEqs eqs, getMVarEqs eqs, getPostEqs eqs)

-- | Convert a set of equalities to a list of equalities.
--
-- POST: Order of equalities equal to order in result of 'toLists'.
toAnyEqs :: Equalities -> [AnyEq]
toAnyEqs eqs = 
  map TIDEq a ++ map TIDRoleEq b ++ map AgentEq c ++ map AVarEq d ++ 
  map  MVarEq e ++ map MsgEq f
  where (a, b, c, d, e, f) = toLists eqs

-- | The threads occurring in an equality.
anyEqTIDs :: AnyEq -> [TID]
anyEqTIDs eq = case eq of
  TIDEq (tid, _)     -> return tid
  TIDRoleEq (tid, _) -> return tid
  RoleEq (_, _)      -> mzero
  AgentEq (_, rhs)   -> either (const mzero) (return . avarTID) rhs
  AVarEq (a1, a2)    -> return (avarTID a1) `mplus` return (avarTID a2)
  MVarEq (v, m)      -> return (mvarTID v)  `mplus` msgTIDs m
  MsgEq (m1, m2)     -> msgTIDs m1          `mplus` msgTIDs m2


-- Unification
--------------

-- | Substitute and normalize the postponed equalities with respect to the
-- other equalities.
normPostEqs :: Equalities -> Equalities
normPostEqs eqs0 = 
    eqs { postEqs = U.map (substMsg eqs) (postEqs eqs0) }
  where
    eqs = eqs0 { postEqs = U.empty }

-- | Solve a list of unification equations.
--
-- The unification is performed modulo key inversion and thread identifier
-- equalities. Additional thread identifier equalities may result from
-- equalities over fresh messages. Bidirectional keys are handled by delaying
-- their solution until only one solution is possible.
solve :: Monad m => [AnyEq] -> Equalities -> m Equalities
solve ueqs eqs = 
  -- trace ("SOLVE: " ++ render (fsep $ punctuate comma $ map sptAnyEq ueqs)) $ 
  fst `liftM` solveRepeated ueqs eqs False

-- | Repeatedly solve unification equations until the solution doesn't change
-- anymore. Postponed equations are tried to be solved again after each full
-- iteration.
--
-- A return value @(neweqs, improvedsolution)@ is to be interpreted such that
-- @improvedsolution@ denotes that something apart from the postponed
-- equalities has changed.
solveRepeated :: Monad m => [AnyEq] -> Equalities -> Bool -> m (Equalities, Bool)
solveRepeated [] eqs False = return (eqs, False)
solveRepeated [] eqs True  = 
    solveRepeated (map MsgEq $ getPostEqs eqs) eqs False
solveRepeated (ueq:ueqs) eqs improved = do
    (ueqs', eqs', improved') <- solve1 ueq eqs
    solveRepeated (ueqs ++ ueqs') (normPostEqs eqs') (improved || improved')

-- | Solve a single unification equation. Equalities are only return when
-- changed.
solve1 :: Monad m => AnyEq -> Equalities -> m ([AnyEq], Equalities, Bool)
solve1 ueq eqs@(Equalities tideqs roleeqs aveqs mveqs agnteqs posteqs) = 
 -- trace ("solve1: " ++ show (sptAnyEq ueq)) $
  case ueq of
    TIDEq (tid1, tid2) ->
      let tid1' = substTID eqs tid1
          tid2' = substTID eqs tid2
          elimTID x y = return
            ( mkAnyEqs TIDRoleEq roleeqs ++ mkAnyEqs AgentEq agnteqs ++ 
              mkAnyEqs AVarEq aveqs ++ mkAnyEqs MVarEq mveqs ++
              map MsgEq (U.toList posteqs)
            , empty { tidEqs = M.insert x y tideqs }
            , True
            )
            where
            mkAnyEqs :: ((k, v) -> AnyEq) -> M.Map k v -> [AnyEq]
            mkAnyEqs constr = map constr . M.toList
      in
        elimVarEqVar elimTID (tid1', tid1') (tid2', tid2')

    TIDRoleEq (tid, role) ->
      let tid' = substTID eqs tid
      in
        case M.lookup tid' roleeqs of
          Just role' | role' /= role -> different "role" role role'
          _                          -> 
            updateSolution (eqs { roleEqs = M.insert tid' role roleeqs })

    RoleEq (role1, role2)
      | role1 == role2 -> skipEq
      | otherwise      -> different "role" role1 role2
            
    AVarEq (av1, av2) ->
      let av1' = substAVar eqs av1
          av2' = substAVar eqs av2
          elimAVar x y = updateSolution (eqs {
              mvarEqs =                M.map (substMsg        elimEqs) mveqs
            , agntEqs =                M.map (substAgentEqRHS elimEqs) agnteqs
            , avarEqs = M.insert x y $ M.map (substAVar       elimEqs) aveqs
            })
            where elimEqs = empty { avarEqs = M.singleton x y }
      in
        elimVarEqVar elimAVar (av1', av1') (av2', av2')

    AgentEq (lhs, rhs) ->
      let elimAgentId x y = updateSolution (eqs {
              mvarEqs =                M.map (substMsg        elimEqs) mveqs
            , agntEqs = M.insert x y $ M.map (substAgentEqRHS elimEqs) agnteqs
            })
            where elimEqs = empty { agntEqs = M.singleton x y }
      in
        case (substAgentId eqs lhs, substAgentEqRHS eqs rhs) of
          (lhs'@(Left aid1), rhs'@(Left aid2)) ->
            elimVarEqVar elimAgentId (aid1, lhs') (aid2, rhs')
          (lhs'@(Right _  ),      (Left aid2)) -> elimAgentId aid2 lhs'
          (     (Left aid1), rhs'@(Right _  )) -> elimAgentId aid1 rhs'
          (     (Right av1),      (Right av2)) -> newEqs [AVarEq (av1, av2)]
    
    MVarEq (lhs, rhs) ->
      let elimMVar x y 
            | x `elem` msgFMV y = 
                noUnifier $ "occurs check failed for '"++show x++"' in '"++show y++"'"
            | otherwise = 
                updateSolution (eqs {
                      mvarEqs =  M.insert x y $ M.map (substMsg elimEqs) mveqs
                    })
                    where elimEqs = empty { mvarEqs = M.singleton x y }
      in
        case (substMVar eqs lhs, substMsg eqs rhs) of
          (lhs'@(MMVar mv1), rhs'@(MMVar mv2)) ->
            elimVarEqVar elimMVar (mv1, lhs') (mv2, rhs')
          (lhs'            ,      (MMVar mv2)) -> elimMVar mv2 lhs'
          (     (MMVar mv1), rhs'            ) -> elimMVar mv1 rhs'
          (lhs'            , rhs'            ) -> newEqs [MsgEq (lhs', rhs')]
            
    MsgEq eq -> case eq of
      (MMVar mv1, rhs) -> newEqs [MVarEq (mv1, rhs)]
      (lhs, MMVar mv2) -> newEqs [MVarEq (mv2, lhs)]

      (MInvKey x,  MInvKey y ) -> newEqs [MsgEq (x, y)]
      (MInvKey x,  MAsymPK m1) -> newEqs [MsgEq (x, MAsymSK m1)]
      (MAsymPK m1, MInvKey x ) -> newEqs [MsgEq (x, MAsymSK m1)]
      (MInvKey x,  MAsymSK m1) -> newEqs [MsgEq (x, MAsymPK m1)]
      (MAsymSK m1, MInvKey x ) -> newEqs [MsgEq (x, MAsymPK m1)]
      (m1,         MInvKey x ) -> newEqs [MsgEq (x, m1)]
      (MInvKey x,  m1        ) -> newEqs [MsgEq (x, m1)]

      (MAgent aid1, MAgent aid2) -> newEqs [AgentEq (aid1, Left aid2)]
      (MAgent aid1, MAVar av2  ) -> newEqs [AgentEq (aid1, Right av2)]
      (MAVar av1,   MAgent aid2) -> newEqs [AgentEq (aid2, Right av1)]

      (MAVar av1, MAVar av2) -> newEqs [AVarEq (av1, av2)]

      (MFresh (Fresh fr1), MFresh (Fresh fr2))
        | lidId fr1 == lidId fr2 -> newEqs [TIDEq (lidTID fr1, lidTID fr2)]
        | otherwise -> different "nonce" fr1 fr2

      (MHash m1,      MHash m2     ) -> newEqs [MsgEq (m1, m2)]
      (MTup m11 m12,  MTup m21 m22 ) -> newEqs [MsgEq (m11, m21), MsgEq (m12, m22)]
      (MEnc m11 m12,  MEnc m21 m22 ) -> newEqs [MsgEq (m11, m21), MsgEq (m12, m22)]
      (MAsymPK m1,    MAsymPK m2   ) -> newEqs [MsgEq (m1, m2)]
      (MAsymSK m1,    MAsymSK m2   ) -> newEqs [MsgEq (m1, m2)]
      (MSymK m11 m12, MSymK m21 m22) -> newEqs [MsgEq (m11, m21), MsgEq (m12, m22)]

      (m1@(MShrK m11 m12), m2@(MShrK m21 m22))
        | m11 == m21                 -> newEqs [MsgEq (m12, m22)]
        | m11 == m22                 -> newEqs [MsgEq (m12, m21)]
        | m12 == m21                 -> newEqs [MsgEq (m11, m22)]
        | m12 == m22                 -> newEqs [MsgEq (m11, m21)]
        | m11 == m12                 -> newEqs [MsgEq (m11, m21), MsgEq (m11, m22)]
        | m21 == m22                 -> newEqs [MsgEq (m11, m21), MsgEq (m12, m21)]
        | (m1, m2) `U.equiv` posteqs -> skipEq
        | otherwise                  -> 
            return ([], eqs { postEqs = U.equate m1 m2 $ posteqs }, False)

      (MConst c1, MConst c2)
        | c1 == c2  -> skipEq
        | otherwise -> different "constant" c1 c2

      (m1, m2) -> different "message" m1 m2
  
  where
  skipEq              = return ([],   eqs , False)
  newEqs ueqs         = return (ueqs, eqs , False)
  updateSolution eqs' = return ([],   eqs', True)
  noUnifier           = fail . ("solve1: " ++)
  different ty x y    = noUnifier $ ty ++ " '" ++ show x ++ "' /= '" ++ show y ++ "'"

  elimVarEqVar elim (vl, lhs) (vr, rhs) =
    case compare vl vr of
      EQ -> skipEq
      LT -> elim vr lhs
      GT -> elim vl rhs


-- | Remove the thread identifier equalities. This is logically safe iff there is no fact
-- outside the equalities that still refers to the dropped thread identifiers.
trimTIDEqs :: Equalities -> ([TID], Equalities) -- ^ Dropped TIDs plus updated equalities
trimTIDEqs eqs = (M.keys . tidEqs $ eqs, eqs { tidEqs = M.empty })

-- | Remove the agent identifiers equalities. This is logically safe iff there is no fact
-- outside the equalities that still refers to the dropped agent identifiers.
trimAgentEqs :: Equalities -> ([AgentId], Equalities) -- ^ Dropped AgentIds plus updated equalities
trimAgentEqs eqs = (M.keys . agntEqs $ eqs, eqs { agntEqs = M.empty })

-- | The maximal mapped thread identifier.
maxMappedTID :: Equalities -> Maybe TID
maxMappedTID = fmap (fst . fst) . M.maxViewWithKey . tidEqs

-- | The maximal mapped agent identifier.
maxMappedAgentId :: Equalities -> Maybe AgentId
maxMappedAgentId = fmap (fst . fst) . M.maxViewWithKey . agntEqs


-- | Retrieve the role of a thread.
threadRole :: TID -> Equalities -> Maybe Role
threadRole tid eqs = M.lookup (substTID eqs tid) $ roleEqs eqs


-------------------------------------------------------------------------------
-- Abusing equalities to represent mappings of logical variables
-------------------------------------------------------------------------------

newtype Mapping = Mapping { getMappingEqs :: Equalities }
  deriving( Eq, Ord, Show, Data, Typeable )

-- | Map the equalities inside a mapping.
mapMapping :: (Equalities -> Equalities) -> Mapping -> Mapping
mapMapping f = Mapping . f . getMappingEqs

-- | An empty mapping.
emptyMapping :: Mapping
emptyMapping = Mapping empty

-- | A mapping of logical variables and the corresponding substitution can be
-- represented as an abstract Equalities value. However, it violates the
-- invariant that the domain of the equalities must be invariant under
-- substitution. This is OK, as domain and range of a mapping are from
-- different logical contexts.
mkMapping :: M.Map TID TID -> M.Map AgentId AgentId -> Mapping
mkMapping tideqs agnteqs = Mapping $
  empty {tidEqs  = tideqs , agntEqs = M.map Left agnteqs}

-- | Add a mapping from one thread identifier to another one, possibly
-- overriding an existing mapping.
addTIDMapping :: TID -> TID -> Mapping -> Mapping
addTIDMapping from to = mapMapping $ \eqs ->
  eqs { tidEqs = M.insert from to $ tidEqs eqs }

-- | Add a mapping from one thread identifier to another one, possibly
-- overriding an existing mapping.
addAgentIdMapping :: AgentId -> AgentId -> Mapping -> Mapping
addAgentIdMapping from to = mapMapping $ \eqs -> 
  eqs { agntEqs = M.insert from (Left to) $ agntEqs eqs }

-- | Add a mapping from one thread identifier to an other role, possibly
-- overriding an existing mapping.
addTIDRoleMapping :: TID -> Role -> Mapping -> Mapping
addTIDRoleMapping tid role = mapMapping $ \eqs -> 
  let tid' = substTID eqs tid
  in  eqs { roleEqs = M.insert tid' role $ roleEqs eqs }

-- | Delete the mapping of the given thread identifier.
deleteTIDMapping :: TID -> Mapping -> Mapping
deleteTIDMapping tid = mapMapping $ \eqs ->
  eqs { tidEqs = M.delete tid $ tidEqs eqs }

-- | Delete the mapping of the given agent identifier.
deleteAgentIdMapping :: AgentId -> Mapping -> Mapping
deleteAgentIdMapping aid = mapMapping $ \eqs ->
  eqs { agntEqs = M.delete aid $ agntEqs eqs }


------------------------------------------------------------------------------
-- Pretty Printing
------------------------------------------------------------------------------

-- Helper functions for pretty printing
---------------------------------------

ppEq :: (a -> Doc) -> (b -> Doc) -> (a, b) -> Doc
ppEq pp1 pp2 (x1, x2) = pp1 x1 <-> char '=' <-> pp2 x2

ppEq' :: (a -> Doc) -> (a, a) -> Doc
ppEq' pp = ppEq pp pp

-- Isar
-------

instance Isar AnyEq where
  isar conf eq0 = case eq0 of
      TIDEq eq  -> ppEq' ppIsar eq
      RoleEq eq -> ppEq' (text . roleName) eq
      TIDRoleEq (tid, role) -> 
        text "roleMap r" <-> ppIsar tid <-> text ("= Some " ++ roleName role)
      AgentEq eq -> ppEq  ppIsar (either ppIsar ppIsar) eq
      AVarEq  eq -> ppEq' ppIsar eq
      MVarEq  eq -> ppEq  ppIsar ppIsar eq
      MsgEq   eq -> ppEq' ppIsar eq
    where
      ppIsar :: Isar a => a -> Doc
      ppIsar = isar conf

-- SP Theory
------------

sptAnyEq :: AnyEq -> Doc
sptAnyEq eq0 = case eq0 of
  TIDEq eq  -> ppEq' sptTID eq
  RoleEq eq -> ppEq' (text . roleName) eq
  TIDRoleEq (tid, role) -> 
    text "role(" <-> sptTID tid <-> text (") = " ++ roleName role)
  AgentEq eq -> ppEq  sptAgentId (either sptAgentId sptAVar) eq
  AVarEq  eq -> ppEq' sptAVar eq
  MVarEq  eq -> ppEq  sptMVar sptMessage eq
  MsgEq   eq -> ppEq' sptMessage eq


{-
-- | Convert the equalities for pretty printing.
sptEqualities :: Equalities -> 
                 ([Doc], [Doc], [Doc]) -- ^ quantified variables, representable
                                       --   equalities, non-representable equalities
sptEqualities (Equalities tideqs roleeqs aveqs mveqs agnteqs) =
  ( map sptTID (M.keys roleeqs) ++
    [ sptAgentId aid | (aid, Nothing) <- M.toList agnteqs]
  , ppMapMaybe ppTIDRoleEq roleeqs ++ 
    ppVarEqs ppAVar ppAVar                 aveqs ++ 
    ppVarEqs ppMVar sptMessage             mveqs ++
    ppVarEqs ppAgent (maybe emptyDoc (either ppAgent ppAVar)) agnteqs
  , ppMap      ppTIDEq  tideqs ++
    ppMapMaybe ppAgentEq agnteqs
  )
  where
  ppAVar = sptMessage . MAVar
  ppMVar = sptMessage . MMVar
  ppAgent = sptMessage . MAgent
  ppMap ppElem = map ppElem . M.toList
  ppMapMaybe ppElem m = map ppElem [(k,v) | (k, Just v) <- M.toList m]
  ppTIDEq (tid1,tid2) = sptTID tid1 <-> text "->" <-> sptTID tid2
  ppTIDRoleEq (tid, role) = text "role(" <> sptTID tid <> text ") =" <-> text (roleName role)
  ppAgentEq (aid, rhs) = sptAgentId aid <-> text "->" <-> either sptAgentId sptLocalId rhs
  ppVarEqs dom ran = ppMap ppVarEq . equalityChains
    where
    ppVarEq (r,ds) = fsep . intersperse (char '=') $ ran r : map dom (S.toList ds)

-- | Compute the equality classes given wrto a partial function.
equalityChains :: (Ord a, Ord b) => M.Map a b -> M.Map b (S.Set a)
equalityChains = foldl' insertEdge M.empty . M.toList
  where
  insertEdge m (from,to) = M.insertWith' S.union to (S.singleton from) m
-}
