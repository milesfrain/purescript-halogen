module Halogen.Driver
  -- ( Driver
  -- , runUI
  -- )
  where

import Prelude

import Control.Bind ((=<<))
import Control.Coroutine (Producer, Consumer, await)
import Control.Coroutine.Stalling (($$?))
import Control.Coroutine.Stalling as SCR
import Control.Monad.Aff (Aff, forkAff, forkAll)
import Control.Monad.Aff.AVar (AVAR, AVar, makeVar, makeVar', putVar, takeVar, modifyVar)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Free (Free, runFreeM, foldFree)
import Control.Monad.Rec.Class (forever, tailRecM)
import Control.Monad.State (runState)
import Control.Monad.Trans (lift)
import Control.Plus (empty)

import Data.Either (Either(..))
import Data.Foldable (class Foldable, foldr)
import Data.Functor.Coproduct (Coproduct, coproduct)
import Data.List (List(Nil), (:), head)
import Data.Map as M
import Data.Maybe (Maybe(..), maybe, isJust, isNothing)
import Data.Tuple (Tuple(..))

import DOM.HTML.Types (HTMLElement, htmlElementToNode)
import DOM.Node.Node (appendChild)

import Halogen.Component (Component, Component', ComponentF, ParentF, ParentDSL, QueryF(..), unComponent, mkComponent)
import Halogen.Component.Hook (Hook(..), Finalized, runFinalized)
import Halogen.Component.Tree (Tree)
import Halogen.Effects (HalogenEffects)
import Halogen.HTML.Renderer.VirtualDOM (renderTree)
import Halogen.Internal.VirtualDOM (VTree, createElement, diff, patch)
import Halogen.Query (HalogenF(..))
import Halogen.Query.HalogenF (RenderPending(..))
import Halogen.Query.EventSource (runEventSource)
import Halogen.Query.StateF (StateF(..), stateN)
import Halogen.Data.OrdBox

import Unsafe.Coerce (unsafeCoerce)

-- | Type alias for driver functions generated by `runUI` - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = f ~> Aff (HalogenEffects eff)

-- | Type alias used internally to track a driver's persistent state.
newtype DriverState s f f' eff p = DriverState (DriverStateR s f f' eff p)

type DriverStateR s f f' eff p =
  { node :: HTMLElement
  , vtree :: VTree
  , renderPending :: Boolean
  , renderPaused :: Boolean
  , component :: Component' s f f' (Aff (HalogenEffects eff)) p
  , state :: s
  , children :: M.Map (OrdBox p) (DSX f' eff)
  , selfRef :: AVar (DriverState s f f' eff p)
  }

unDriverState :: forall s f f' eff p. DriverState s f f' eff p -> DriverStateR s f f' eff p
unDriverState (DriverState r) = r

type DSL s f f' eff p = ParentDSL s f f' (Aff (HalogenEffects eff)) p

data DSX (f :: * -> *) (eff :: # !)

mkDSX
  :: forall s f f' eff p
   . DriverState s f f' eff p
  -> DSX f eff
mkDSX = unsafeCoerce

unDSX
  :: forall f eff r
   . (forall s f' p. DriverState s f f' eff p -> r)
  -> DSX f eff
  -> r
unDSX = unsafeCoerce unit

mkState
  :: forall f eff
   . HTMLElement
  -> VTree
  -> Component f (Aff (HalogenEffects eff))
  -> Aff (HalogenEffects eff) (DSX f eff)
mkState node vtree = unComponent \component -> do
  selfRef <- makeVar
  let
    ds =
      DriverState
        { node
        , vtree
        , renderPending: false
        , renderPaused: false
        , component
        , state: component.initialState
        , children: M.empty
        , selfRef
        }
  putVar selfRef ds
  pure $ mkDSX ds

-- | This function is the main entry point for a Halogen based UI, taking a root
-- | component, initial state, and HTML element to attach the rendered component
-- | to.
-- |
-- | The returned "driver" function can be used to send actions and requests
-- | into the component hierarchy, allowing the outside world to communicate
-- | with the UI.
-- runUI
--   :: forall f eff
--    . Functor f
--   => Component f (Aff (HalogenEffects eff))
--   -> HTMLElement
--   -> Aff (HalogenEffects eff) (Driver f eff)
-- runUI component element = _.driver <$> do
--   ref <- makeVar
--   let rc = renderComponent component
--       dr = driver ref :: Driver f eff
--   --     vtree = renderTree dr rc.tree
--   --     node = createElement vtree
--   -- putVar ref
--   --   { node: node
--   --   , vtree: vtree
--   --   , component: rc.component
--   --   , renderPending: false
--   --   , renderPaused: true
--   --   }
--   -- liftEff $ appendChild (htmlElementToNode node) (htmlElementToNode element)
--   -- forkAll $ onInitializers dr rc.hooks
--   -- -- forkAff $ maybe (pure unit) dr (initializeComponent component)
--   -- modifyVar _ { renderPaused = false } ref
--   -- flushRender ref
--   pure { driver: dr }
--
--   -- where

-- driver
--   :: forall f eff
--    . Component f (Aff (HalogenEffects eff))
--   -> Driver f eff
-- driver component q = unComponent (\c -> do
--   ref <- makeVar
--   rpRef <- makeVar' Nothing
--   stateRef <- makeVar' (mkState c.state)
--   x <- runFreeM (eval c.eval ref stateRef rpRef) (c.eval q)
--   rp <- takeVar rpRef
--   when (isJust rp) $ render ref
--   pure x) component

eval
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> AVar (Maybe RenderPending)
  -> DSL s f g eff p
  ~> Aff (HalogenEffects eff)
eval ref rpRef = case _ of
  StateHF i -> do
    ds <- takeVar ref
    case i of
      Get k -> do
        putVar ref ds
        DriverState st <- peekVar ref
        pure (k st.state)
      Modify f next -> do
        rp <- takeVar rpRef
        modifyVar (\(DriverState st) -> DriverState (st { state = f st.state })) ref
        putVar rpRef $ Just Pending
        pure next
  SubscribeHF es next -> do
    let producer :: SCR.StallingProducer (ParentF f g (Aff (HalogenEffects eff)) p Unit) (Aff (HalogenEffects eff)) Unit
        producer = runEventSource es
        consumer :: forall a. Consumer (ParentF f g (Aff (HalogenEffects eff)) p Unit) (Aff (HalogenEffects eff)) a
        consumer = forever (lift <<< evalPF ref rpRef =<< await)
    forkAff $ SCR.runStallingProcess (producer $$? consumer)
    pure next
  RenderHF p next -> do
    modifyVar (const p) rpRef
    when (isNothing p) $ render ref
    pure next
  RenderPendingHF k -> do
    rp <- takeVar rpRef
    putVar rpRef rp
    pure $ k rp
  QueryFHF q ->
    coproduct (evalQ ref rpRef) (evalF ref rpRef) q
  QueryGHF q -> do
    rp <- takeVar rpRef
    when (isJust rp) $ render ref
    putVar rpRef Nothing
    q
  HaltHF -> empty

evalPF
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> AVar (Maybe RenderPending)
  -> ParentF f g (Aff (HalogenEffects eff)) p
  ~> Aff (HalogenEffects eff)
evalPF ref rpRef = coproduct (evalQ ref rpRef) (evalF ref rpRef)

evalQ
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> AVar (Maybe RenderPending)
  -> QueryF g (Aff (HalogenEffects eff)) p
  ~> Aff (HalogenEffects eff)
evalQ ref rpRef = case _ of
  GetSlots k -> do
    st <- unDriverState <$> peekVar ref
    pure $ k $ map unOrdBox $ M.keys st.children
  RunQuery p k -> do
    st <- unDriverState <$> peekVar ref
    -- TODO: something less ridiculous than this for `updateOrdBox` - we just
    -- need to grab any existing OrdBox
    let ob = head $ M.keys $ st.children
    case flip M.lookup st.children <<< updateOrdBox p =<< ob of
      Nothing -> k Nothing
      Just dsx ->
        let
          -- All of these annotations are required to prevent skolem escape issues
          nat :: g ~> Aff (HalogenEffects eff)
          nat = unDSX (\(DriverState ds) -> evalF ds.selfRef rpRef) dsx
          j :: forall h i. (h ~> i) -> Maybe (h ~> i)
          j = Just
        in
          k (j nat)

evalF
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> AVar (Maybe RenderPending)
  -> (f ~> Aff (HalogenEffects eff))
evalF ref rpRef q = do
  st <- unDriverState <$> peekVar ref
  foldFree (eval ref rpRef) (st.component.eval q)

peekVar :: forall eff a. AVar a -> Aff (avar :: AVAR | eff) a
peekVar v = do
  a <- takeVar v
  putVar v a
  pure a

render
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> Aff (HalogenEffects eff) Unit
render ref = do
  unsafeCoerce unit
  -- ds <- takeVar ref
  -- if ds.renderPaused
  --   then putVar ref $ ds { renderPending = true }
  --   else renderComponent component \rc -> do
  --     let vtree' = renderTree (driver ref) rc.tree
  --     node' <- liftEff $ patch (diff ds.vtree vtree') ds.node
  --     putVar ref
  --       { node: node'
  --       , vtree: vtree'
  --       , component: rc.component
  --       , renderPending: false
  --       , renderPaused: true
  --       }
  --     -- forkAll $ onFinalizers (runFinalized driver') rc.hooks
  --     forkAll $ onInitializers (driver ref) rc.hooks
  --     modifyVar _ { renderPaused = false } ref
  --     flushRender ref

-- flushRender :: forall f eff. AVar (DSX f eff) -> Aff (HalogenEffects eff) Unit
-- flushRender = tailRecM \ref -> do
--   ds <- takeVar ref
--   putVar ref ds
--   if not ds.renderPending
--     then pure (Right unit)
--     else do
--       render ref
--       pure (Left ref)

onInitializers
  :: forall m f g r
   . Foldable m
  => (f Unit -> r)
  -> m (Hook f g)
  -> List r
onInitializers f = foldr go Nil
  where
  go (PostRender a) as = f a : as
  go _ as = as

onFinalizers
  :: forall m f g r
   . Foldable m
  => (Finalized g -> r)
  -> m (Hook f g)
  -> List r
onFinalizers f = foldr go Nil
  where
  go (Finalized a) as = f a : as
  go _ as = as

type RR s f f' g p =
  { component :: Component f g
  , hooks :: Array (Hook f g)
  , tree  :: Tree (ParentF f f' g p) Unit
  }

-- initializeComponent :: forall f g. Component f g -> Maybe (f Unit)
-- initializeComponent = unComponent _.initializer

-- renderComponent :: forall f g r. Component f g -> (forall s f' p. RR s f f' g p -> r) -> r
-- renderComponent comp f =
--   unComponent (\c ->
--     let
--       rr = c.render c.state
--       c' = mkComponent (c { state = rr.state })
--     in
--       f { hooks: rr.hooks, tree: rr.tree, component: c' }) comp
