{-|
A description of the operations that can be performed on
nodes and columns.
-}
module Spark.Core.Internal.OpStructures where

import Data.Text as T
import Data.Aeson(Value, Value(Null))
import Data.Vector(Vector)

import Spark.Core.StructuresInternal
import Spark.Core.Internal.TypesStructures(DataType, SQLType, SQLType(unSQLType))

{-| The name of a SQL function.

It is one of the predefined SQL functions available in Spark.
-}
type SqlFunctionName = T.Text

{-| The classpath of a UDAF.
-}
type UdafClassName = T.Text

{-| The name of an operator defined in Kraps.
-}
type OperatorName = T.Text

{-| The invariant respected by a transform.

Depending on the value of the invariant, different optimizations
may be available.
-}
data TransformInvariant =
    -- | This operator has no special property. It may depend on
    -- the partitioning layout, the number of partitions, the order
    -- of elements in the partitions, etc.
    -- This sort of operator is unwelcome in Krapsh...
    Opaque
    -- | This operator respects the canonical partition order, but may
    -- not have the same number of elements.
    -- For example, this could be a flatMap on an RDD (filter, etc.).
    -- This operator can be used locally with the signature a -> [a]
  | PartitioningInvariant
    -- | The strongest invariant. It respects the canonical partition order
    -- and it outputs the same number of elements.
    -- This is typically a map.
    -- This operator can be used locally with the signature a -> a
  | DirectPartitioningInvariant


-- | The dynamic value of locality.
-- There is still a tag on it, but it can be easily dropped.
data Locality =
    -- | The data associated to this node is local. It can be materialized
    -- and accessed by the user.
    Local
    -- | The data associated to this node is distributed or not accessible
    -- locally. It cannot be accessed by the user.
  | Distributed deriving (Show, Eq)

-- ********* PHYSICAL OPERATORS ***********
-- These structures declare some operations that correspond to operations found
-- in Spark itself, or in the surrounding libraries.

-- | An operator defined by default in the release of Krapsh.
-- All other physical operators can be converted to a standard operators.
data StandardOperator = StandardOperator {
  soName :: !OperatorName,
  soOutputType :: !DataType,
  soExtra :: !Value
} deriving (Eq, Show)

-- | A scala method of a singleton object.
data ScalaStaticFunctionApplication = ScalaStaticFunctionApplication {
  sfaObjectName :: !T.Text,
  sfaMethodName :: !T.Text
  -- TODO add the input and output types?
}


-- | The different kinds of column operations.
-- These operations describe the physical operations on columns as supported
-- by Spark SQL. They can operate on column -> column, column -> row, row->row.
-- Of course, not all operators are valid for each configuration.
data ColOp =
    -- | A projection onto a single column
    -- An extraction is always direct.
    ColExtraction !FieldPath
    -- | A function of other columns.
    -- In this case, the other columns may matter
    -- TODO(kps) add if this function is partition invariant.
    -- It should be the case most of the time.
  | ColFunction !SqlFunctionName !(Vector ColOp)
    -- | A constant defined for each element.
    -- The type should be the same as for the column
    -- A literal is always direct
  | ColLit !DataType !Value
    -- | A structure.
  | ColStruct !(Vector TransformField)
  deriving (Eq, Show)

-- | A field in a structure.
data TransformField = TransformField {
  tfName :: !FieldName,
  tfValue :: !ColOp
} deriving (Eq, Show)

-- | The content of a structured transform.
data StructuredTransform =
    InnerOp !ColOp
  | InnerStruct !(Vector TransformField)
  deriving (Eq, Show)

{-| When applying a UDAF, determines if it should only perform the algebraic
portion of the UDAF (initialize+update+merge), or if it also performs the final,
non-algebraic step.
-}
data UdafApplication = Algebraic | Complete deriving (Eq, Show)

data AggOp =
    -- The name of the UDAF and the field path to apply it onto.
    AggUdaf !UdafApplication !UdafClassName !FieldPath
    -- A column function that can be applied (sum, max, etc.)
  | AggFunction !SqlFunctionName !(Vector FieldPath)
  | AggStruct !(Vector AggField)
  deriving (Eq, Show)

{-| A field in the resulting aggregation transform.
-}
data AggField = AggField {
  afName :: !FieldName,
  afValue :: !AggOp
} deriving (Eq, Show)

{-| Unlike the structured transforms, the aggregation transforms do not allow
nesting of elements.

This is not a limitation in practice, as a nesting can be appended after an
aggregation transform.
-}
data AggTransform =
    OpaqueAggTransform !StandardOperator
  | InnerAggOp !AggOp
  | InnerAggStruct !(Vector AggField) deriving (Eq, Show)

{-| The representation of a semi-group law in Spark.

This is the basic law used in universal aggregators. It is a function on
observables that must respect the following laws:

f :: X -> X -> X
commutative
associative

A neutral element is not required for the semi-group laws. However, if used in
the context of a universal aggregator, such an element implicitly exists and
corresponds to the empty dataset.
-}
data SemiGroupOperator =
    -- | A standard operator that happens to respect the semi-group laws.
    OpaqueSemiGroupLaw !StandardOperator
    -- | The merging portion of a UDAF
  | UdafSemiGroupOperator !UdafClassName
    -- | A SQL operator that happens to respect the semi-group laws.
  | ColumnSemiGroupLaw !SqlFunctionName deriving (Eq, Show)

-- ********* DATASET OPERATORS ************
-- These describe Dataset -> Dataset transforms.


data DatasetTransformDesc =
    DSScalaStaticFunction !ScalaStaticFunctionApplication
  | DSStructuredTransform !ColOp
  | DSOperator !StandardOperator


-- ****** OBSERVABLE OPERATORS *******
-- These operators describe Observable -> Observable transforms

-- **** AGGREGATION OPERATORS *****
-- The different types of aggregators

-- The low-level description of a
-- The name of the aggregator is the name of the
-- Dataset -> Local data transform
data UniversalAggregatorOp = UniversalAggregatorOp {
  uaoMergeType :: !DataType,
  uaoInitialOuter :: !AggTransform,
  uaoMergeBuffer :: !SemiGroupOperator
} deriving (Eq, Show)


data NodeOp2 =
  -- empty -> local
    NodeLocalLiteral !DataType !Value
  -- empty -> distributed
  | NodeDistributedLiteral !DataType !(Vector Value)
  -- distributed -> local
  | NodeStructuredAggregation !AggOp !(Maybe UniversalAggregatorOp)
  -- distributed -> distributed or local -> local
  | NodeStructuredTransform2 !Locality !ColOp
  -- [distributed, local] -> [local, distributed] opaque
  | NodeOpaqueTransform !Locality StandardOperator
  deriving (Eq, Show)


{-
A node operation.
A description of all the operations between nodes.
These are the low-level, physical operations that Spark implements.

Each node operation is associated with:
 - a locality
 - an operation name (implicit or explicit)
 - a data type
 - a representation in JSON

Additionally, some operations are associated with algebraic invariants
to enable programmatic transformations.
-}
data NodeOp =
    -- | An operation between local nodes: [Observable] -> Observable
    NodeLocalOp StandardOperator
    -- | An observable literal
  | NodeLocalLit !DataType !Value
    -- | Some aggregator that does not respect any particular invariant.
  | NodeOpaqueAggregator StandardOperator
    -- | A universal aggregator.
  | NodeAggregatorReduction UniversalAggregatorOp
  | NodeAggregatorLocalReduction UniversalAggregatorOp
    -- | A structured transform, performed either on a local node or a
    -- distributed node.
  | NodeStructuredTransform !ColOp
    -- | A distributed dataset (with no partition information)
  | NodeDistributedLit !DataType !(Vector Value)
    -- | An opaque distributed operator.
  | NodeDistributedOp StandardOperator
  deriving (Eq, Show)

-- | Makes a standard operator with no extra value
makeOperator :: T.Text -> SQLType a -> StandardOperator
makeOperator txt sqlt =
  StandardOperator {
    soName = txt,
    soOutputType = unSQLType sqlt,
    soExtra = Null }
