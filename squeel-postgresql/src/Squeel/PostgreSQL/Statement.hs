{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# LANGUAGE
    DataKinds
  , FlexibleInstances
  , FunctionalDependencies
  , GADTs
  , LambdaCase
  , MagicHash
  , OverloadedStrings
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeel.PostgreSQL.Statement where

import Data.Boolean
import Data.Boolean.Numbers
import Data.ByteString (ByteString)
import Data.Maybe
import Data.Monoid
import Data.Ratio
import Data.String
import Generics.SOP
import GHC.Exts
import GHC.OverloadedLabels
import GHC.TypeLits
import Prelude hiding (RealFrac(..))

import qualified Data.ByteString as ByteString

import Squeel.PostgreSQL.Schema

{-----------------------------------------
column expressions
-----------------------------------------}

newtype Expression
  (params :: [ColumnType])
  (tables :: [(Symbol,[(Symbol,ColumnType)])])
  (ty :: ColumnType)
    = UnsafeExpression { renderExpression :: ByteString }
    deriving (Show,Eq)

class KnownNat n => HasParameter (n :: Nat) params ty | n params -> ty where
  param :: Proxy# n -> Expression params tables ty
  param p = UnsafeExpression $ ("$" <>) $ fromString $ show $ natVal' p
instance {-# OVERLAPPING #-} HasParameter 1 (ty1:tys) ty1
instance {-# OVERLAPPABLE #-} (KnownNat n, HasParameter (n-1) params ty)
  => HasParameter n (ty' : params) ty

param1 :: Expression (ty1:tys) tables ty1
param1 = param (proxy# :: Proxy# 1)
param2 :: Expression (ty1:ty2:tys) tables ty2
param2 = param (proxy# :: Proxy# 2)
param3 :: Expression (ty1:ty2:ty3:tys) tables ty3
param3 = param (proxy# :: Proxy# 3)
param4 :: Expression (ty1:ty2:ty3:ty4:tys) tables ty4
param4 = param (proxy# :: Proxy# 4)
param5 :: Expression (ty1:ty2:ty3:ty4:ty5:tys) tables ty5
param5 = param (proxy# :: Proxy# 5)

class KnownSymbol column => HasColumn column columns ty
  | column columns -> ty where
    getColumn :: Proxy# column -> Expression params '[table ::: columns] ty
    getColumn column = UnsafeExpression $ fromString $ symbolVal' column
instance {-# OVERLAPPING #-} KnownSymbol column
  => HasColumn column ((column ::: optionality ty) ': tys) ('Required ty)
instance {-# OVERLAPPABLE #-} (KnownSymbol column, HasColumn column table ty)
  => HasColumn column (ty' ': table) ty

instance (HasColumn column columns ty, tables ~ '[table ::: columns])
  => IsLabel column (Expression params tables ty) where
    fromLabel = getColumn

(&.)
  :: (HasTable table tables columns, HasColumn column columns ty)
  => Alias table -> Alias column -> Expression params tables ty
Alias table &. Alias column = UnsafeExpression $
  fromString (symbolVal' table)
  <> "." <>
  fromString (symbolVal' column)

def :: Expression params '[] ('Optional (nullity ty))
def = UnsafeExpression "DEFAULT"

notDef
  :: Expression params '[] ('Required (nullity ty))
  -> Expression params '[] ('Optional (nullity ty))
notDef = UnsafeExpression . renderExpression

null :: Expression params tables (optionality ('Null ty))
null = UnsafeExpression "NULL"

coalesce
  :: [Expression params tables ('Required ('Null x))]
  -> Expression params tables ('Required ('NotNull x))
  -> Expression params tables ('Required ('NotNull x))
coalesce nulls isn'tNull = UnsafeExpression $ mconcat
  [ "COALESCE("
  , ByteString.intercalate ", " $ map renderExpression nulls
  , ", ", renderExpression isn'tNull
  , ")"
  ]

unsafeBinaryOp
  :: ByteString
  -> Expression params tables ty0
  -> Expression params tables ty1
  -> Expression params tables ty2
unsafeBinaryOp op x y = UnsafeExpression $ mconcat
  ["(", renderExpression x, " ", op, " ", renderExpression y, ")"]

unsafeUnaryOp
  :: ByteString
  -> Expression params tables ty0
  -> Expression params tables ty1
unsafeUnaryOp op x = UnsafeExpression $ mconcat
  ["(", op, " ", renderExpression x, ")"]

unsafeFunction
  :: ByteString
  -> Expression params tables xty
  -> Expression params tables yty
unsafeFunction fun x = UnsafeExpression $ mconcat
  [fun, "(", renderExpression x, ")"]

instance PGNum ty
  => Num (Expression params tables ('Required (nullity ty))) where
    (+) = unsafeBinaryOp "+"
    (-) = unsafeBinaryOp "-"
    (*) = unsafeBinaryOp "*"
    abs = unsafeFunction "abs"
    signum = unsafeFunction "sign"
    fromInteger
      = UnsafeExpression
      . (<> if decimal (Proxy :: Proxy ty) then "." else "")
      . fromString
      . show

instance PGFractional ty
  => Fractional (Expression params tables ('Required (nullity ty))) where
    (/) = unsafeBinaryOp "/"
    fromRational x = fromInteger (numerator x) / fromInteger (denominator x)

instance (PGFloating ty, PGCast 'PGNumeric ty, PGTyped ty)
  => Floating (Expression params tables ('Required (nullity ty))) where
    pi = UnsafeExpression "pi()"
    exp = unsafeFunction "exp"
    log = unsafeFunction "ln"
    sqrt = unsafeFunction "sqrt"
    b ** x = UnsafeExpression $
      "power(" <> renderExpression b <> ", " <> renderExpression x <> ")"
    logBase b y = cast pgtype $ logBaseNumeric b y
      where
        logBaseNumeric
          :: Expression params tables ('Required (nullity ty))
          -> Expression params tables ('Required (nullity ty))
          -> Expression params tables ('Required (nullity 'PGNumeric))
        logBaseNumeric b' y' = UnsafeExpression $ mconcat
          [ "log("
          , renderExpression b' <> "::numeric"
          , ", "
          , renderExpression y' <> "::numeric"
          , ")"
          ]
    sin = unsafeFunction "sin"
    cos = unsafeFunction "cos"
    tan = unsafeFunction "tan"
    asin = unsafeFunction "asin"
    acos = unsafeFunction "acos"
    atan = unsafeFunction "atan"
    sinh x = (exp x - exp (-x)) / 2
    cosh x = (exp x + exp (-x)) / 2
    tanh x = sinh x / cosh x
    asinh x = log (x + sqrt (x*x + 1))
    acosh x = log (x + sqrt (x*x - 1))
    atanh x = log ((1 + x) / (1 - x)) / 2

class PGCast (ty0 :: PGType) (ty1 :: PGType) where
  cast
    :: TypeExpression ('Required ('Null ty1))
    -> Expression params tables ('Required (nullity ty0))
    -> Expression params tables ('Required (nullity ty1))
  cast ty x = UnsafeExpression $
    "(" <> renderExpression x <> "::" <> renderTypeExpression ty <> ")"
instance PGCast 'PGInt2 'PGInt2
instance PGCast 'PGInt2 'PGInt4
instance PGCast 'PGInt2 'PGInt8
instance PGCast 'PGInt4 'PGInt2
instance PGCast 'PGInt4 'PGInt4
instance PGCast 'PGInt4 'PGInt8
instance PGCast 'PGInt8 'PGInt2
instance PGCast 'PGInt8 'PGInt4
instance PGCast 'PGInt8 'PGInt8
instance PGCast 'PGInt8 'PGFloat4
instance PGCast 'PGInt8 'PGFloat8
instance PGCast 'PGInt8 'PGNumeric

instance (PGNum ty, PGTyped ty, PGCast 'PGInt8 ty)
  => NumB (Expression params tables ('Required (nullity ty))) where
    type IntegerOf (Expression params tables ('Required (nullity ty)))
      = (Expression params tables ('Required (nullity 'PGInt8)))
    fromIntegerB = cast pgtype

instance (PGNum ty, PGTyped ty, PGCast 'PGInt8 ty, PGCast ty 'PGInt8)
  => IntegralB (Expression params tables ('Required ('NotNull ty))) where
    quot = unsafeBinaryOp "/"
    rem = unsafeBinaryOp "%"
    div = unsafeBinaryOp "/"
    mod = unsafeBinaryOp "%"
    toIntegerB = cast int8

instance
  ( IntegerOf (Expression params tables ('Required ('NotNull ty)))
    ~ (Expression params tables ('Required ('NotNull 'PGInt8)))
  , PGNum ty
  , PGTyped ty
  , PGCast 'PGInt8 ty
  , PGFractional ty
  )
  => RealFracB (Expression params tables ('Required ('NotNull ty))) where
    properFraction x = (truncate x, x - unsafeFunction "trunc" x)
    truncate = fromIntegerB . unsafeFunction "trunc"
    round = fromIntegerB . unsafeFunction "round"
    ceiling = fromIntegerB . unsafeFunction "ceiling"
    floor = fromIntegerB . unsafeFunction "floor"

instance
  ( IntegerOf (Expression params tables ('Required ('NotNull ty)))
    ~ (Expression params tables ('Required ('NotNull 'PGInt8)))
  , PGNum ty
  , PGTyped ty
  , PGCast 'PGInt8 ty
  , PGCast 'PGNumeric ty
  , PGFloating ty
  )
  => RealFloatB (Expression params tables ('Required ('NotNull ty))) where
    isNaN x = x ==* UnsafeExpression "\'NaN\'"
    isInfinite x = x ==* UnsafeExpression "\'Infinity\'"
      ||* x ==* UnsafeExpression "\'-Infinity\'"
    isNegativeZero x = x ==* UnsafeExpression "-0"
    isIEEE _ = true
    atan2 y x = UnsafeExpression $
      "atan2(" <> renderExpression y <> ", " <> renderExpression x <> ")"

instance IsString (Expression params tables ('Required (nullity 'PGText))) where
  fromString str = UnsafeExpression $
    "E\'" <> fromString (escape =<< str) <> "\'"
    where
      escape = \case
        '\NUL' -> "\\0"
        '\'' -> "''"
        '"' -> "\\\""
        '\b' -> "\\b"
        '\n' -> "\\n"
        '\r' -> "\\r"
        '\t' -> "\\t"
        '\\' -> "\\\\"
        c -> [c]

instance Boolean (Expression params tables ('Required ('NotNull 'PGBool))) where
  true = UnsafeExpression "TRUE"
  false = UnsafeExpression "FALSE"
  notB = unsafeUnaryOp "NOT"
  (&&*) = unsafeBinaryOp "AND"
  (||*) = unsafeBinaryOp "OR"

type instance BooleanOf (Expression params tables ty) =
  Expression params tables ('Required ('NotNull 'PGBool))

caseWhenThenElse
  :: [(Expression params tables ('Required ('NotNull 'PGBool)), Expression params tables ty)]
  -> Expression params tables ty
  -> Expression params tables ty
caseWhenThenElse whenThens else_ = UnsafeExpression $ mconcat
  [ "CASE"
  , mconcat
    [ mconcat
      [ " WHEN ", renderExpression when_
      , " THEN ", renderExpression then_
      ]
    | (when_,then_) <- whenThens
    ]
  , " ELSE ", renderExpression else_
  , " END"
  ]

instance IfB (Expression params tables ty) where
  ifB if_ then_ else_ = caseWhenThenElse [(if_,then_)] else_

instance EqB (Expression params tables (optionality ('NotNull ty))) where
  (==*) = unsafeBinaryOp "="
  (/=*) = unsafeBinaryOp "<>"

instance OrdB (Expression params tables (optionality ('NotNull ty))) where
  (>*) = unsafeBinaryOp ">"
  (>=*) = unsafeBinaryOp ">="
  (<*) = unsafeBinaryOp "<"
  (<=*) = unsafeBinaryOp "<="

{-----------------------------------------
table expressions
-----------------------------------------}

newtype TableExpression
  (params :: [ColumnType])
  (schema :: [(Symbol,[(Symbol,ColumnType)])])
  (columns :: [(Symbol,ColumnType)])
    = UnsafeTableExpression { renderTableExpression :: ByteString }
    deriving (Show,Eq)

class KnownSymbol table => HasTable table tables columns
  | table tables -> columns where
    getTable :: Proxy# table -> TableExpression params tables columns
    getTable table = UnsafeTableExpression $ fromString $ symbolVal' table
instance {-# OVERLAPPING #-} KnownSymbol table
  => HasTable table ((table ::: columns) ': tables) columns
instance {-# OVERLAPPABLE #-}
  (KnownSymbol table, HasTable table schema columns)
    => HasTable table (table' ': schema) columns

instance HasTable table schema columns
  => IsLabel table (TableExpression params schema columns) where
    fromLabel = getTable

{-----------------------------------------
statements
-----------------------------------------}

newtype Statement
  (params :: [ColumnType])
  (columns :: [(Symbol,ColumnType)])
  (schema0 :: [(Symbol,[(Symbol,ColumnType)])])
  (schema1 :: [(Symbol,[(Symbol,ColumnType)])])
    = UnsafeStatement { renderStatement :: ByteString }
    deriving (Show,Eq)

newtype PreparedStatement
  (params :: [ColumnType])
  (columns :: [(Symbol,ColumnType)])
  (schema0 :: [(Symbol,[(Symbol,ColumnType)])])
  (schema1 :: [(Symbol,[(Symbol,ColumnType)])])
    = UnsafePreparedStatement { renderPreparedStatement :: ByteString }
    deriving (Show,Eq)

{-----------------------------------------
SELECT statements
-----------------------------------------}

data Join params schema tables where
  Table
    :: Aliased (TableExpression params schema) table
    -> Join params schema '[table]
  Subselect
    :: Aliased (Selection params schema) table
    -> Join params schema '[table]
  Cross
    :: Aliased (TableExpression params schema) table
    -> Join params schema tables
    -> Join params schema (table ': tables)
  Inner
    :: Aliased (TableExpression params schema) table
    -> Expression params (table ': tables) ('Required ('NotNull 'PGBool))
    -> Join params schema tables
    -> Join params schema (table ': tables)
  LeftOuter
    :: Aliased (TableExpression params schema) right
    -> Expression params '[left,right] ('Required ('NotNull 'PGBool))
    -> Join params schema (tables)
    -> Join params schema (NullifyTable right ': left ': tables)
  RightOuter
    :: Aliased (TableExpression params schema) right
    -> Expression params '[left,right] ('Required ('NotNull 'PGBool))
    -> Join params schema (left : tables)
    -> Join params schema (right ': NullifyTable left ': tables)
  FullOuter
    :: Aliased (TableExpression params schema) right
    -> Expression params '[left,right] ('Required ('NotNull 'PGBool))
    -> Join params schema (left : tables)
    -> Join params schema
        (NullifyTable right ': NullifyTable left ': tables)

renderJoin :: Join params schema tables -> ByteString
renderJoin = \case
  Table table -> renderAliased renderTableExpression table
  Subselect selection -> "SELECT " <> renderAliased renderSelection selection
  Cross table tables -> mconcat
    [ renderJoin tables
    , " CROSS JOIN "
    , renderAliased renderTableExpression table
    ]
  Inner table on tables -> mconcat
    [ renderJoin tables
    , " INNER JOIN "
    , renderAliased renderTableExpression table
    , " ON "
    , renderExpression on
    ]
  LeftOuter table on tables -> mconcat
    [ renderJoin tables
    , " LEFT OUTER JOIN "
    , renderAliased renderTableExpression table
    , " ON "
    , renderExpression on
    ]
  RightOuter table on tables -> mconcat
    [ renderJoin tables
    , " RIGHT OUTER JOIN "
    , renderAliased renderTableExpression table
    , " ON "
    , renderExpression on
    ]
  FullOuter table on tables -> mconcat
    [ renderJoin tables
    , " FULL OUTER JOIN "
    , renderAliased renderTableExpression table
    , " ON "
    , renderExpression on
    ]

instance HasTable table schema columns
  => IsLabel table (Join params schema '[table ::: columns]) where
    fromLabel p = Table $ fromLabel p

data Clauses params tables = Clauses
  { whereClause :: Maybe (Expression params tables ('Required ('NotNull 'PGBool)))
  , limitClause :: Maybe (Expression params '[] ('Required ('NotNull 'PGInt8)))
  , offsetClause :: Maybe (Expression params '[] ('Required ('NotNull 'PGInt8)))
  }

instance Monoid (Clauses params tables) where
  mempty = Clauses Nothing Nothing Nothing
  Clauses wh1 lim1 off1 `mappend` Clauses wh2 lim2 off2 = Clauses
    { whereClause = case (wh1,wh2) of
        (Nothing,Nothing) -> Nothing
        (Just w1,Nothing) -> Just w1
        (Nothing,Just w2) -> Just w2
        (Just w1,Just w2) -> Just (w1 &&* w2)
    , limitClause = case (lim1,lim2) of
        (Nothing,Nothing) -> Nothing
        (Just l1,Nothing) -> Just l1
        (Nothing,Just l2) -> Just l2
        (Just l1,Just l2) -> Just (l1 `minB` l2)
    , offsetClause = case (off1,off2) of
        (Nothing,Nothing) -> Nothing
        (Just o1,Nothing) -> Just o1
        (Nothing,Just o2) -> Just o2
        (Just o1,Just o2) -> Just (o1 + o2)
    }

data From
  (params :: [ColumnType])
  (schema :: [(Symbol,[(Symbol,ColumnType)])])
  (tables :: [(Symbol,[(Symbol,ColumnType)])])
    = From
    { fromJoin :: Join params schema tables
    , fromClauses :: Clauses params tables
    }

join
  :: Join params schema tables
  -> From params schema tables
join tables = From tables mempty

renderFrom :: From params schema tables -> ByteString
renderFrom (From tref (Clauses wh lim off))= mconcat
  [ renderJoin tref
  , maybe "" ((" WHERE " <>) . renderExpression) wh
  , maybe "" ((" LIMIT " <>) . renderExpression) lim
  , maybe "" ((" OFFSET " <>) . renderExpression) off
  ]

instance (HasTable table schema columns, table ~ table')
  => IsLabel table (From params schema '[table' ::: columns]) where
    fromLabel p = From (fromLabel p) mempty

where_
  :: Expression params tables ('Required ('NotNull 'PGBool))
  -> From params schema tables
  -> From params schema tables
where_ wh (From tabs fromClauses1) = From tabs
  (fromClauses1 <> Clauses (Just wh) Nothing Nothing)

limit
  :: Expression params '[] ('Required ('NotNull 'PGInt8))
  -> From params schema tables
  -> From params schema tables
limit lim (From tabs fromClauses1) = From tabs
  (fromClauses1 <> Clauses Nothing (Just lim) Nothing)

offset
  :: Expression params '[] ('Required ('NotNull 'PGInt8))
  -> From params schema tables
  -> From params schema tables
offset off (From tabs fromClauses1) = From tabs
  (fromClauses1 <> Clauses Nothing Nothing (Just off))

newtype Selection
  (params :: [ColumnType])
  (schema :: [(Symbol,[(Symbol,ColumnType)])])
  (columns :: [(Symbol,ColumnType)])
    = UnsafeSelection { renderSelection :: ByteString }
    deriving (Show,Eq)

starFrom
  :: tables ~ '[table ::: columns]
  => From params schema tables
  -> Selection params schema columns
starFrom tabs = UnsafeSelection $ "* FROM " <> renderFrom tabs

dotStarFrom
  :: HasTable table tables columns
  => Alias table
  -> From params schema tables
  -> Selection params schema columns
Alias tab `dotStarFrom` tabs = UnsafeSelection $
  fromString (symbolVal' tab) <> ".* FROM " <> renderFrom tabs

from
  :: SListI columns
  => NP (Aliased (Expression params tables)) columns
  -> From params schema tables
  -> Selection params schema columns
list `from` tabs = UnsafeSelection $
  renderList list <> " FROM " <> renderFrom tabs
  where
    renderList
      = ByteString.intercalate ", "
      . hcollapse
      . hmap (K . renderAliased renderExpression)

select
  :: Selection params schema columns
  -> Statement params columns schema schema
select = UnsafeStatement . ("SELECT " <>) . (<> ";") . renderSelection

subselect
  :: Aliased (Selection params schema) table
  -> From params schema '[table]
subselect selection = From
  { fromJoin = Subselect selection
  , fromClauses = mempty
  }

{-----------------------------------------
INSERT statements
-----------------------------------------}

insertInto
  :: (SListI columns, HasTable table schema columns)
  => Alias table
  -> NP (Aliased (Expression params '[])) columns
  -> Statement params '[] schema schema
insertInto (Alias table) expressions = UnsafeStatement $ "INSERT INTO "
  <> fromString (symbolVal' table)
  <> " (" <> ByteString.intercalate ", " aliases
  <> ") VALUES ("
  <> ByteString.intercalate ", " values
  <> ");"
  where
    aliases = hcollapse $ hmap
      (\ (_ `As` Alias name) -> K (fromString (symbolVal' name)))
      expressions
    values = hcollapse $ hmap
      (\ (expression `As` _) -> K (renderExpression expression))
      expressions

{-----------------------------------------
CREATE statements
-----------------------------------------}

newtype TypeExpression (ty :: ColumnType)
  = UnsafeTypeExpression { renderTypeExpression :: ByteString }
  deriving (Show,Eq)

bool :: TypeExpression ('Required ('Null 'PGBool))
bool = UnsafeTypeExpression "bool"
int2 :: TypeExpression ('Required ('Null 'PGInt2))
int2 = UnsafeTypeExpression "int2"
smallint :: TypeExpression ('Required ('Null 'PGInt2))
smallint = UnsafeTypeExpression "smallint"
int4 :: TypeExpression ('Required ('Null 'PGInt4))
int4 = UnsafeTypeExpression "int4"
int :: TypeExpression ('Required ('Null 'PGInt4))
int = UnsafeTypeExpression "int"
integer :: TypeExpression ('Required ('Null 'PGInt4))
integer = UnsafeTypeExpression "integer"
int8 :: TypeExpression ('Required ('Null 'PGInt8))
int8 = UnsafeTypeExpression "int8"
bigint :: TypeExpression ('Required ('Null 'PGInt8))
bigint = UnsafeTypeExpression "bigint"
numeric :: TypeExpression ('Required ('Null 'PGNumeric))
numeric = UnsafeTypeExpression "numeric"
float4 :: TypeExpression ('Required ('Null 'PGFloat4))
float4 = UnsafeTypeExpression "float4"
real :: TypeExpression ('Required ('Null 'PGFloat4))
real = UnsafeTypeExpression "real"
float8 :: TypeExpression ('Required ('Null 'PGFloat8))
float8 = UnsafeTypeExpression "float8"
doublePrecision :: TypeExpression ('Required ('Null 'PGFloat8))
doublePrecision = UnsafeTypeExpression "double precision"
serial2 :: TypeExpression ('Optional ('NotNull 'PGInt2))
serial2 = UnsafeTypeExpression "serial2"
smallserial :: TypeExpression ('Optional ('NotNull 'PGInt2))
smallserial = UnsafeTypeExpression "smallserial"
serial4 :: TypeExpression ('Optional ('NotNull 'PGInt4))
serial4 = UnsafeTypeExpression "serial4"
serial :: TypeExpression ('Optional ('NotNull 'PGInt4))
serial = UnsafeTypeExpression "serial"
serial8 :: TypeExpression ('Optional ('NotNull 'PGInt8))
serial8 = UnsafeTypeExpression "serial8"
bigserial :: TypeExpression ('Optional ('NotNull 'PGInt8))
bigserial = UnsafeTypeExpression "bigserial"
money :: TypeExpression ('Required ('Null 'PGMoney))
money = UnsafeTypeExpression "money"
text :: TypeExpression ('Required ('Null 'PGText))
text = UnsafeTypeExpression "text"
char
  :: KnownNat n
  => proxy n
  -> TypeExpression ('Required ('Null ('PGChar n)))
char (_ :: proxy n) = UnsafeTypeExpression $
  "char(" <> fromString (show (natVal' (proxy# :: Proxy# n))) <> ")"
character
  :: KnownNat n
  => proxy n
  -> TypeExpression ('Required ('Null ('PGChar n)))
character (_ :: proxy n) = UnsafeTypeExpression $
  "character(" <> fromString (show (natVal' (proxy# :: Proxy# n))) <> ")"
varchar
  :: KnownNat n
  => proxy n
  -> TypeExpression ('Required ('Null ('PGVarChar n)))
varchar (_ :: proxy n) = UnsafeTypeExpression $
  "varchar(" <> fromString (show (natVal' (proxy# :: Proxy# n))) <> ")"
characterVarying
  :: KnownNat n
  => proxy n
  -> TypeExpression ('Required ('Null ('PGVarChar n)))
characterVarying (_ :: proxy n) = UnsafeTypeExpression $
  "character varying(" <> fromString (show (natVal' (proxy# :: Proxy# n))) <> ")"
bytea :: TypeExpression ('Required ('Null ('PGBytea)))
bytea = UnsafeTypeExpression "bytea"
timestamp :: TypeExpression ('Required ('Null ('PGTimestamp)))
timestamp = UnsafeTypeExpression "timestamp"
timestampWithTimeZone :: TypeExpression ('Required ('Null ('PGTimestampTZ)))
timestampWithTimeZone = UnsafeTypeExpression "timestamp with time zone"
date :: TypeExpression ('Required ('Null ('PGDate)))
date = UnsafeTypeExpression "date"
time :: TypeExpression ('Required ('Null ('PGTime)))
time = UnsafeTypeExpression "time"
timeWithTimeZone :: TypeExpression ('Required ('Null ('PGTimeTZ)))
timeWithTimeZone = UnsafeTypeExpression "time with time zone"
interval :: TypeExpression ('Required ('Null ('PGInterval)))
interval = UnsafeTypeExpression "interval"
uuid :: TypeExpression ('Required ('Null ('PGUuid)))
uuid = UnsafeTypeExpression "uuid"
json :: TypeExpression ('Required ('Null ('PGJson)))
json = UnsafeTypeExpression "json"
jsonb :: TypeExpression ('Required ('Null ('PGJsonb)))
jsonb = UnsafeTypeExpression "jsonb"

notNull
  :: TypeExpression ('Required ('Null ty))
  -> TypeExpression ('Required ('NotNull ty))
notNull ty = UnsafeTypeExpression $ renderTypeExpression ty <> " NOT NULL"
default_
  :: Expression '[] '[] ('Required ty)
  -> TypeExpression ('Required ty)
  -> TypeExpression ('Optional ty)
default_ x ty = UnsafeTypeExpression $
  renderTypeExpression ty <> " DEFAULT " <> renderExpression x

class PGTyped (ty :: PGType) where
  pgtype :: TypeExpression ('Required ('Null ty))
instance PGTyped 'PGBool where pgtype = bool
instance PGTyped 'PGInt2 where pgtype = int2
instance PGTyped 'PGInt4 where pgtype = int4
instance PGTyped 'PGInt8 where pgtype = int8
instance PGTyped 'PGNumeric where pgtype = numeric
instance PGTyped 'PGFloat4 where pgtype = float4
instance PGTyped 'PGFloat8 where pgtype = float8
instance PGTyped 'PGMoney where pgtype = money
instance PGTyped 'PGText where pgtype = text
instance KnownNat n => PGTyped ('PGChar n) where pgtype = char (Proxy @n)
instance KnownNat n => PGTyped ('PGVarChar n) where pgtype = varchar (Proxy @n)
instance PGTyped 'PGBytea where pgtype = bytea
instance PGTyped 'PGTimestamp where pgtype = timestamp
instance PGTyped 'PGTimestampTZ where pgtype = timestampWithTimeZone
instance PGTyped 'PGDate where pgtype = date
instance PGTyped 'PGTime where pgtype = time
instance PGTyped 'PGTimeTZ where pgtype = timeWithTimeZone
instance PGTyped 'PGInterval where pgtype = interval
instance PGTyped 'PGUuid where pgtype = uuid
instance PGTyped 'PGJson where pgtype = json
instance PGTyped 'PGJsonb where pgtype = jsonb

createTable
  :: (KnownSymbol table, SListI columns)
  => Alias table
  -> NP (Aliased TypeExpression) columns
  -> Statement '[] '[] schema ((table ::: columns) ': schema)
createTable (Alias table) columns = UnsafeStatement $ mconcat
  [ "CREATE TABLE "
  , fromString $ symbolVal' table
  , " ("
  , ByteString.intercalate ", " . hcollapse $
      hmap (K . renderColumn) columns
  , ");"
  ]
  where
    renderColumn :: Aliased TypeExpression x -> ByteString
    renderColumn (ty `As` Alias column) =
      fromString (symbolVal' column) <> " " <> renderTypeExpression ty

{-----------------------------------------
DROP statements
-----------------------------------------}

class KnownSymbol table => DropTable table schema0 schema1
  | table schema0 -> schema1 where
    dropTable :: Alias table -> Statement '[] '[] schema0 schema1
    dropTable (Alias table) = UnsafeStatement $
      "DROP TABLE " <> fromString (symbolVal' table) <> ";"
instance {-# OVERLAPPING #-}
  (KnownSymbol table, table ~ table', schema ~ schema')
    => DropTable table ((table' ::: columns) ': schema) schema'
instance {-# OVERLAPPABLE #-}
  DropTable table schema0 schema1
    => DropTable table (table' ': schema0) (table' ': schema1)

{-----------------------------------------
UPDATE statements
-----------------------------------------}

set :: g x -> (Maybe :.: g) x
set = Comp . Just

same :: (Maybe :.: g) x
same = Comp Nothing

update
  :: (HasTable table schema columns, SListI columns)
  => Alias table
  -> NP (Aliased (Maybe :.: Expression params '[table ::: columns])) columns
  -> Expression params '[table ::: columns] ('Required ('NotNull 'PGBool))
  -> Statement params '[] schema schema
update (Alias table) columns where' = UnsafeStatement $ mconcat
  [ "UPDATE "
  , fromString $ symbolVal' table
  , " SET "
  , ByteString.intercalate ", " . catMaybes . hcollapse $
      hmap (K . renderSet) columns
  , " WHERE ", renderExpression where'
  ] where
    renderSet
      :: Aliased (Maybe :.: Expression params tables) column
      -> Maybe ByteString
    renderSet = \case
      Comp (Just expression) `As` Alias column -> Just $ mconcat
        [ fromString $ symbolVal' column
        , " = "
        , renderExpression expression
        ]
      Comp Nothing `As` _ -> Nothing