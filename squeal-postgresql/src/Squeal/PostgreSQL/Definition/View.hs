{-|
Module: Squeal.PostgreSQL.Definition.View
Description: create and drop views
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

create and drop views
-}

{-# LANGUAGE
    AllowAmbiguousTypes
  , ConstraintKinds
  , DeriveAnyClass
  , DeriveGeneric
  , DerivingStrategies
  , FlexibleContexts
  , FlexibleInstances
  , GADTs
  , LambdaCase
  , MultiParamTypeClasses
  , OverloadedLabels
  , OverloadedStrings
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeInType
  , TypeOperators
  , UndecidableSuperClasses
#-}

module Squeal.PostgreSQL.Definition.View
  ( -- * Create
    createView
  , createOrReplaceView
    -- * Drop
  , dropView
  , dropViewIfExists
  ) where

import GHC.TypeLits

import qualified Generics.SOP as SOP

import Squeal.PostgreSQL.Type.Alias
import Squeal.PostgreSQL.Definition
import Squeal.PostgreSQL.Query
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Type.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

{- | Create a view.

>>> type ABC = '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4]
>>> type BC = '["b" ::: 'Null 'PGint4, "c" ::: 'Null 'PGint4]
>>> :{
let
  definition :: Definition
    '[ "public" ::: '["abc" ::: 'Table ('[] :=> ABC)]]
    '[ "public" ::: '["abc" ::: 'Table ('[] :=> ABC), "bc"  ::: 'View BC]]
  definition =
    createView #bc (select_ (#b :* #c) (from (table #abc)))
in printSQL definition
:}
CREATE VIEW "bc" AS SELECT "b" AS "b", "c" AS "c" FROM "abc" AS "abc";
-}
createView
  :: (Has sch db schema, KnownSymbol vw)
  => SOP.K (Alias sch) vw -- ^ the name of the view to add
  -> Query '[] '[] db '[] view -- ^ query
  -> Definition db (Alter sch (Create vw ('View view) schema) db)
createView alias query = UnsafeDefinition $
  "CREATE" <+> "VIEW" <+> renderSQL alias <+> "AS"
  <+> renderQuery query <> ";"

{- | Create or replace a view.

>>> type ABC = '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4]
>>> type BC = '["b" ::: 'Null 'PGint4, "c" ::: 'Null 'PGint4]
>>> :{
let
  definition :: Definition
    '[ "public" ::: '["abc" ::: 'Table ('[] :=> ABC)]]
    '[ "public" ::: '["abc" ::: 'Table ('[] :=> ABC), "bc"  ::: 'View BC]]
  definition =
    createOrReplaceView #bc (select_ (#b :* #c) (from (table #abc)))
in printSQL definition
:}
CREATE OR REPLACE VIEW "bc" AS SELECT "b" AS "b", "c" AS "c" FROM "abc" AS "abc";
-}
createOrReplaceView
  :: (Has sch db schema, KnownSymbol vw)
  => SOP.K (Alias sch) vw -- ^ the name of the view to add
  -> Query '[] '[] db '[] view -- ^ query
  -> Definition db (Alter sch (CreateOrReplace vw ('View view) schema) db)
createOrReplaceView alias query = UnsafeDefinition $
  "CREATE OR REPLACE VIEW" <+> renderSQL alias <+> "AS"
  <+> renderQuery query <> ";"

-- | Drop a view.
--
-- >>> :{
-- let
--   definition :: Definition
--     '[ "public" ::: '["abc" ::: 'Table ('[] :=> '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4])
--      , "bc"  ::: 'View ('["b" ::: 'Null 'PGint4, "c" ::: 'Null 'PGint4])]]
--     '[ "public" ::: '["abc" ::: 'Table ('[] :=> '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4])]]
--   definition = dropView #bc
-- in printSQL definition
-- :}
-- DROP VIEW "bc";
dropView
  :: (Has sch db schema, KnownSymbol vw)
  => SOP.K (Alias sch) vw -- ^ view to remove
  -> Definition db (Alter sch (DropSchemum vw 'View schema) db)
dropView vw = UnsafeDefinition $ "DROP VIEW" <+> renderSQL vw <> ";"

-- | Drop a view if it exists.
--
-- >>> :{
-- let
--   definition :: Definition
--     '[ "public" ::: '["abc" ::: 'Table ('[] :=> '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4])
--      , "bc"  ::: 'View ('["b" ::: 'Null 'PGint4, "c" ::: 'Null 'PGint4])]]
--     '[ "public" ::: '["abc" ::: 'Table ('[] :=> '["a" ::: 'NoDef :=> 'Null 'PGint4, "b" ::: 'NoDef :=> 'Null 'PGint4, "c" ::: 'NoDef :=> 'Null 'PGint4])]]
--   definition = dropViewIfExists #bc
-- in printSQL definition
-- :}
-- DROP VIEW IF EXISTS "bc";
dropViewIfExists
  :: (Has sch db schema, KnownSymbol vw)
  => SOP.K (Alias sch) vw -- ^ view to remove
  -> Definition db (Alter sch (DropIfExists vw schema) db)
dropViewIfExists vw = UnsafeDefinition $
  "DROP VIEW IF EXISTS" <+> renderSQL vw <> ";"
