{-# LANGUAGE CPP #-}

-- | Rewriting with arbitrary rules.
--
--   The user specifies a relation symbol by the pragma
--   @
--       {-# BUILTIN REWRITE rel #-}
--   @
--   where @rel@ should be of type @Δ → (lhs rhs : A) → Set i@.
--
--   Then the user can add rewrite rules by the pragma
--   @
--       {-# REWRITE q #-}
--   @
--   where @q@ should be a closed term of type @Γ → rel us lhs rhs@.
--
--   We then intend to add a rewrite rule
--   @
--       Γ ⊢ lhs ↦ rhs : B
--   @
--   to the signature where @B = A[us/Δ]@.
--
--   To this end, we normalize @lhs@, which should be of the form
--   @
--       f ts
--   @
--   for a @'Def'@-symbol f (postulate, function, data, record, constructor).
--   Further, @FV(ts) = dom(Γ)@.
--   The rule @q :: Γ ⊢ f ts ↦ rhs : B@ is added to the signature
--   to the definition of @f@.
--
--   When reducing a term @Ψ ⊢ f vs@ is stuck, we try the rewrites for @f@,
--   by trying to unify @vs@ with @ts@.
--   This is for now done by substituting fresh metas Xs for the bound
--   variables in @ts@ and checking equality with @vs@
--   @
--       Ψ ⊢ (f ts)[Xs/Γ] = f vs : B[Xs/Γ]
--   @
--   If successful (no open metas/constraints), we replace @f vs@ by
--   @rhs[Xs/Γ]@ and continue reducing.

module Agda.TypeChecking.Rewriting where

import Control.Monad
import Control.Monad.Reader (local)

import Agda.Syntax.Common
import Agda.Syntax.Internal as I

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.EtaContract
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope

import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Size

#include "undefined.h"
import Agda.Utils.Impossible

-- | Check that the name given to the BUILTIN REWRITE is actually
--   a relation symbol.
--   I.e., its type should be of the form @Δ → (lhs rhs : A) → Set ℓ@.
--   Note: we do not care about hiding/non-hiding of lhs and rhs.
verifyBuiltinRewrite :: Term -> Type -> TCM ()
verifyBuiltinRewrite v t = do
  let failure reason = typeError . GenericDocError =<< sep
       [ prettyTCM v <+> text " does not have the right type for a rewriting relation"
       , reason
       ]
  caseMaybeM (relView t)
    (failure $ text "because it should accept at least two arguments") $
    \ (RelView tel delta a b core) -> do
  case ignoreSharing (unEl core) of
    Sort{} -> do
      -- Check that the types of the last two arguments are equal.
      unlessM (tryConversion $
                 inTopContext $ addContext tel $ escapeContext 1 $
                   equalType (raise 1 a) b) $
        failure $ text $ "because the types of the last two arguments are different"
    Con{}    -> __IMPOSSIBLE__
    Level{}  -> __IMPOSSIBLE__
    Lam{}    -> __IMPOSSIBLE__
    Pi{}     -> __IMPOSSIBLE__
    Shared{} -> __IMPOSSIBLE__
    _ -> failure $ text "because its type does not end in a sort, but in "
           <+> do inTopContext $ addContext tel $ prettyTCM core

-- | Deconstructing a type into @Δ → t → t' → core@.
data RelView = RelView
  { relViewTel   :: Telescope  -- ^ The whole telescope @Δ, t, t'@.
  , relViewDelta :: ListTel    -- ^ @Δ@.
  , relViewType  :: Type       -- ^ @t@.
  , relViewType' :: Type       -- ^ @t'@.
  , relViewCore  :: Type       -- ^ @core@.
  }

-- | Deconstructing a type into @Δ → t → t' → core@.
--   Returns @Nothing@ if not enough argument types.
relView :: Type -> TCM (Maybe RelView)
relView t = do
  TelV tel core <- telView t
  let n                = size tel
      (delta, lastTwo) = splitAt (n - 2) $ telToList tel
  if size lastTwo < 2 then return Nothing else do
  let [a, b] = snd . unDom <$> lastTwo
  return $ Just $ RelView tel delta a b core

-- | Add @q : Γ → rel us lhs rhs@ as rewrite rule
--   @
--       Γ ⊢ lhs ↦ rhs : B
--   @
--   to the signature where @B = A[us/Δ]@.
--   Remember that @rel : Δ → A → A → Set i@, so
--   @rel us : (lhs rhs : A[us/Δ]) → Set i@.
addRewriteRule :: QName -> TCM ()
addRewriteRule q = do
  let failureWrongTarget = typeError . GenericDocError =<< sep
        [ prettyTCM q , text " does not target rewrite relation" ]
  let failureMetas       = typeError . GenericDocError =<< sep
        [ prettyTCM q , text " is not a legal rewrite rule, since it contains unsolved meta variables" ]
  let failureFreeVars    = typeError . GenericDocError =<< sep
        [ prettyTCM q , text " is not a legal rewrite rule, since not all variables are bound by the left hand side" ]
  let failureIllegalRule = typeError . GenericDocError =<< sep
        [ prettyTCM q , text " is not a legal rewrite rule" ]
  Def rel _ <- primRewrite
  -- We know that the type of rel is that of a relation.
  Just (RelView _tel delta a _a' _core) <- relView =<< do
    defType <$> getConstInfo rel
  reportSDoc "rewriting" 30 $ do
    text "rewrite relation at type " <+> do
    inTopContext     $ prettyTCM (telFromList delta) <+> text " |- " <+> do
    addContext delta $ prettyTCM a
  -- Get rewrite rule (type of q).
  t <- defType <$> getConstInfo q
  TelV gamma core <- telView t
  -- Check that type of q targets rel.
  case ignoreSharing $ unEl core of
    Def rel' es@(_:_:_) | rel == rel' -> do
      -- Because of the type of rel (Γ → sort), all es are applications.
      let vs = map unArg $ fromMaybe __IMPOSSIBLE__ $ allApplyElims es
      -- The last two arguments are lhs and rhs.
          n  = size vs
          (us, [lhs, rhs]) = splitAt (n - 2) vs
      unless (size delta == size us) __IMPOSSIBLE__
      let b  = applySubst (parallelS $ reverse us) a
      -- Normalize lhs: we do not want to match redexes.
      lhs <- etaContract =<< normalise lhs
      -- Normalize rhs: might be more efficient.
      rhs <- etaContract =<< normalise rhs
      unless (null $ allMetas (telToList gamma, lhs, rhs, b)) failureMetas
      let rew = RewriteRule q gamma lhs rhs b
      reportSDoc "rewriting" 10 $
        text "considering rewrite rule " <+> prettyTCM rew
      -- Check whether lhs can be rewritten with itself.
      -- Otherwise, there are unbound variables in either gamma or rhs.
      addContext gamma $
        unlessM (isJust <$> rewriteWith (Just b) lhs rew) $
          failureFreeVars
      -- Find head symbol f of the lhs.
      case ignoreSharing lhs of
        Def f _ -> do
          -- Add rewrite rule gamma ⊢ lhs ↦ rhs : b for f.
          addRewriteRules f [rew]
        _ -> failureIllegalRule
    _ -> failureWrongTarget

-- | Append rewrite rules to a definition.
addRewriteRules :: QName -> RewriteRules -> TCM ()
addRewriteRules f rews =
  modifySignature $ updateDefinition f $ updateRewriteRules $ (++ rews)

-- | Lens for 'RewriteRules'.
updateRewriteRules :: (RewriteRules -> RewriteRules) -> Definition -> Definition
updateRewriteRules f def = def { defRewriteRules = f (defRewriteRules def) }

-- | @rewriteWith t v rew@
--   tries to rewrite @v : t@ with @rew@, returning the reduct if successful.
rewriteWith :: Maybe Type -> Term -> RewriteRule -> TCM (Maybe Term)
rewriteWith mt v (RewriteRule q gamma lhs rhs b) = do
  xs <- newTelMeta gamma
  let sigma        = parallelS $ map unArg xs
      (lhs', rhs', b') = applySubst sigma (lhs, rhs, b)
  ok <- tryConversion $ do
    -- Unify type and term with type and lhs of rewrite rule.
    whenJust mt $ \ t -> leqType t b'
    local (\ e -> e {envCompareBlocked = True}) $ equalTerm b' lhs' v
    -- Check that all variables have been solved for.
    unlessM (isInstantiatedMeta xs) $ do
      reportSDoc "rewriting" 20 $ text "lhs variables solved with: " <+> do
        sep $ map prettyTCM xs
      -- The following error is caught immediately by tryConversion.
      typeError $ GenericError $ "free variables not bound by left hand side"
  if ok then return $ Just rhs' else return Nothing

-- | @rewrite t@ tries to rewrite a reduced term.
rewrite :: Term -> TCM (Maybe Term)
rewrite v = do
  case ignoreSharing v of
    -- We only rewrite @Def@s.
    Def f es -> do
      -- Get the rewrite rules for f.
      rews <- defRewriteRules <$> getConstInfo f
      loop rews
        where
          loop [] = return Nothing
          loop (rew:rews) = do
            caseMaybeM (rewriteWith Nothing v rew) (loop rews) (return . Just)
    _ -> return Nothing
