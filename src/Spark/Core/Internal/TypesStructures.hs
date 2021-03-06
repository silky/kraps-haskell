{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{-| The structures of data types in Krapsh.

For a detailed description of the supported types, see
http://spark.apache.org/docs/latest/sql-programming-guide.html#data-types

At a high-level, Spark DataFrames and Datasets are equivalent to lists of
objects whose type can be mapped to the same StructType:
Dataset a ~ ArrayType StructType (...)
Columns of a dataset are equivalent to lists of object whose type can be
mapped to the same DataType (either Strict or Nullable)
Local data (or "blobs") are single elements whose type can be mapped to a
DataType (either strict or nullable)
-}
module Spark.Core.Internal.TypesStructures where

import Data.Aeson
import Data.Vector(Vector)
import qualified Data.Vector as V
import qualified Data.Aeson as A
import qualified Data.Text as T
import GHC.Generics(Generic)
import Test.QuickCheck

import Spark.Core.StructuresInternal(FieldName(..))
import Spark.Core.Internal.Utilities


-- The core type algebra

-- | The data types that are guaranteed to not be null: evaluating them will return a value.
data StrictDataType =
    IntType
  | StringType
  | Struct !StructType
  | ArrayType { elementType :: !DataType } deriving (Eq)

-- | All the data types supported by the Spark engine.
-- The data types can either be nullable (they may contain null values) or strict (all the values are present).
-- There are a couple of differences with the algebraic data types in Haskell:
-- Maybe (Maybe a) ~ Maybe a which implies that arbitrary nesting of values will be flattened to a top-level Nullable
-- Similarly, [[]] ~ []
data DataType =
    StrictType !StrictDataType
  | NullableType !StrictDataType deriving (Eq)

-- | A field in a structure
data StructField = StructField {
  structFieldName :: !FieldName,
  structFieldType :: !DataType
} deriving (Eq)

-- | The main structure of a dataframe or a dataset
data StructType = StructType {
  structFields :: !(Vector StructField)
} deriving (Eq)


-- Convenience types

-- | Represents the choice between a strict and a nullable field
data Nullable = CanNull | NoNull deriving (Show, Eq)

-- | Encodes the type of all the nullable data types
data NullableDataType = NullableDataType !StrictDataType deriving (Eq)

-- | A tagged datatype that encodes the sql types
-- This is the main type information that should be used by users.
data SQLType a = SQLType {
  -- | The underlying data type.
  unSQLType :: !DataType
} deriving (Eq, Generic)


instance Show DataType where
  show (StrictType x) = show x
  show (NullableType x) = show x ++ "?"

instance Show StrictDataType where
  show StringType = "string"
  show IntType = "int"
  show (Struct struct) = show struct
  show array = "[" ++ show (elementType array) ++ "]"

instance Show StructField where
  show field = (T.unpack . unFieldName . structFieldName) field ++ ":" ++ s where
    s = show $ structFieldType field

instance Show StructType where
  show struct = "{" ++ unwords (map show (V.toList . structFields $ struct)) ++ "}"

instance Show (SQLType a) where
  show (SQLType dt) = show dt


-- QUICKCHECK INSTANCES


instance Arbitrary StructField where
  arbitrary = do
    name <- elements ["_1", "a", "b", "abc"]
    dt <- arbitrary :: Gen DataType
    return $ StructField (FieldName $ T.pack name) dt

instance Arbitrary StructType where
  arbitrary = do
    fields <- listOf arbitrary
    return . StructType . V.fromList $ fields

instance Arbitrary StrictDataType where
  arbitrary = do
    idx <- elements [1,2] :: Gen Int
    return $ case idx of
      1 -> StringType
      2 -> IntType
      _ -> failure "Arbitrary StrictDataType"

instance Arbitrary DataType where
  arbitrary = do
    x <- arbitrary
    u <- arbitrary
    return $ if x then
      StrictType u
    else
      NullableType u

-- AESON INSTANCES

-- This follows the same structure as the JSON generated by Spark.
instance ToJSON StrictDataType where
  toJSON IntType = "integer"
  toJSON StringType = "string"
  toJSON (Struct struct) = toJSON struct
  toJSON (ArrayType (StrictType dt)) =
    object [ "type" .= A.String "array"
           , "elementType" .= toJSON dt
           , "containsNull" .= A.Bool False ]
  toJSON (ArrayType (NullableType dt)) =
    object [ "type" .= A.String "array"
           , "elementType" .= toJSON dt
           , "containsNull" .= A.Bool True ]

instance ToJSON StructType where
  toJSON (StructType fields) =
    let
      fs = (snd . _fieldToJson) <$> V.toList fields
    in object [ "type" .= A.String "struct"
              , "fields" .= fs ]

-- Spark drops the info at the highest level.
instance ToJSON DataType where
  toJSON (StrictType dt) = object [
    "nullable" .= A.Bool False,
    "dt" .= toJSON dt]
  toJSON (NullableType dt) = object [
    "nullable" .= A.Bool True,
    "dt" .= toJSON dt]

_fieldToJson :: StructField -> (T.Text, A.Value)
_fieldToJson (StructField (FieldName n) (StrictType dt)) =
  (n, object [ "name" .= A.String n
             , "type" .= toJSON dt
             , "nullable" .= A.Bool False])
_fieldToJson (StructField (FieldName n) (NullableType dt)) =
  (n, object [ "name" .= A.String n
             , "type" .= toJSON dt
             , "nullable" .= A.Bool True])
