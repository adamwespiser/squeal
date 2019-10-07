{-# LANGUAGE
    DataKinds
  , OverloadedLabels
  , OverloadedStrings
  , TypeOperators
#-}

module Squeal.Skeleton.Database.Schema.V1 where

import Squeal.PostgreSQL

type Schemas = Public Schema
type Schema =
  '[ "user" ::: 'Table UserTable
   , "token" ::: 'Table TokenTable
   ]

type UserTable = UserConstraints :=> UserColumns
type UserColumns =
  '[ "id" ::: 'Def :=> 'NotNull 'PGint8
   , "created_at" ::: 'Def :=> 'NotNull 'PGtimestamptz
   , "username" ::: 'NoDef :=> 'NotNull 'PGtext
   , "password" ::: 'NoDef :=> 'NotNull 'PGtext
   , "email" ::: 'NoDef :=> 'NotNull 'PGtext
   , "is_active" ::: 'Def :=> 'NotNull 'PGbool ]
type UserConstraints =
  '[ "pk_id" ::: 'PrimaryKey '["id"]
   , "uq_username" ::: 'Unique '["username"]
   , "uq_email" ::: 'Unique '["email"] ]

type TokenTable = TokenConstraints :=> TokenColumns
type TokenColumns =
  '[ "id" ::: 'Def :=> 'NotNull 'PGint8
   , "token" ::: 'NoDef :=> 'Null 'PGuuid
   , "token_type" ::: 'NoDef :=> 'NotNull 'PGtext
   , "user_id" ::: 'NoDef :=> 'NotNull 'PGint8
   , "created_at" ::: 'Def :=> 'NotNull 'PGtimestamptz
   , "valid_until" ::: 'NoDef :=> 'NotNull 'PGtimestamptz ]
type TokenConstraints =
  '[ "pk_id" ::: 'PrimaryKey '["id"]
   , "uq_token" ::: 'Unique '["token"]
   , "fk_user_id" ::: 'ForeignKey '["user_id"] "user" '["id"] ]

setup :: Definition (Public '[]) Schemas
setup =
  createTable #user
    ( bigserial `as` #id :*
      (notNullable timestamptz & default_ now) `as` #created_at :*
      notNullable text `as` #username :*
      notNullable text `as` #password :*
      notNullable text `as` #email :*
      (notNullable bool & default_ false) `as` #is_active )
    ( primaryKey #id `as` #pk_id :*
      unique #username `as` #uq_username :*
      unique #email `as` #uq_email ) >>>
  createTable #token
    ( bigserial `as` #id :*
      nullable uuid `as` #token :*
      notNullable text `as` #token_type :*
      notNullable int8 `as` #user_id :*
      (notNullable timestamptz & default_ now) `as` #created_at :*
      notNullable timestamptz `as` #valid_until)
    ( primaryKey #id `as` #pk_id :*
      unique #token `as` #uq_token :*
      foreignKey #user_id #user #id
        OnDeleteCascade OnUpdateCascade `as` #fk_user_id )

teardown :: Definition Schemas (Public '[])
teardown = dropTable #token >>> dropTable #user

migration :: Migration Definition (Public '[]) Schemas
migration = Migration
  { name = "v1"
  , up = setup
  , down = teardown
  }
