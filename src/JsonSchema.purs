module JsonSchema where

import Doc
import IRGraph
import Prelude

import Data.Argonaut.Core (Json, foldJson, fromArray, fromBoolean, fromObject, fromString, isBoolean, stringifyWithSpace)
import Data.Argonaut.Decode ((.??), decodeJson, class DecodeJson)
import Data.Array as A
import Data.Char as Char
import Data.Either (Either(..), either)
import Data.Foldable (class Foldable, foldM, intercalate)
import Data.List (List, (:))
import Data.List as L
import Data.List.NonEmpty as NEL
import Data.Map (Map)
import Data.Map as M
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as S
import Data.StrMap (StrMap)
import Data.StrMap as SM
import Data.String as String
import Data.String.Util (camelCase, capitalize, singular)
import Data.Traversable (class Traversable)
import Data.Tuple (Tuple(..))
import IR (IR, addClass, unifyMultipleTypes, unifyTypes)
import Utils (foldError, mapM, mapMapM, mapStrMapM)

data JSONType
    = JSONObject
    | JSONArray
    | JSONBoolean
    | JSONString
    | JSONNull
    | JSONInteger
    | JSONNumber

derive instance eqJSONType :: Eq JSONType
derive instance ordJSONType :: Ord JSONType

jsonTypeEnumMap :: StrMap JSONType
jsonTypeEnumMap = SM.fromFoldable [
    Tuple "object" JSONObject, Tuple "array" JSONArray, Tuple "boolean" JSONBoolean,
    Tuple "string" JSONString, Tuple "null" JSONNull, Tuple "integer" JSONInteger,
    Tuple "number" JSONNumber
    ]

newtype JSONSchemaRef = JSONSchemaRef (NEL.NonEmptyList String)

newtype JSONSchema = JSONSchema
    { definitions :: Maybe (StrMap JSONSchema)
    , ref :: Maybe JSONSchemaRef
    , types :: Maybe (Either JSONType (Set JSONType))
    , oneOf :: Maybe (Array JSONSchema)
    , properties :: Maybe (StrMap JSONSchema)
    , additionalProperties :: Either Boolean JSONSchema
    , items :: Maybe JSONSchema
    , required :: Maybe (Array String)
    , title :: Maybe String
    }

decodeEnum :: forall a. StrMap a -> Json -> Either String a
decodeEnum sm j = do
    key <- decodeJson j
    maybe (Left "Unexpected enum key") Right $ SM.lookup key sm

instance decodeJsonType :: DecodeJson JSONType where
    decodeJson = decodeEnum jsonTypeEnumMap

instance decodeJsonSchemaRef :: DecodeJson JSONSchemaRef where
    decodeJson j = do
        ref <- decodeJson j
        case NEL.fromFoldable $ String.split (String.Pattern "/") ref of
            Just nel -> pure $ JSONSchemaRef nel
            Nothing -> Left "ERROR: String.split should return at least one element."

decodeTypes :: Maybe Json -> Either String (Maybe (Either JSONType (Set JSONType)))
decodeTypes Nothing = Right Nothing
decodeTypes (Just j) =
    foldJson
        (\_ -> Left "`types` cannot be null")
        (\_ -> Left "`types` cannot be a boolean")
        (\_ -> Left "`types` cannot be a number")
        (\s -> either Left (\t -> Right $ Just $ Left t) $ decodeEnum jsonTypeEnumMap j)
        (\a -> either Left (\l -> Right $ Just $ Right $ S.fromFoldable l) $ foldError $ map (decodeEnum jsonTypeEnumMap) a)
        (\_ -> Left "`Types` cannot be an object")
        j

decodeAdditionalProperties :: Maybe Json -> Either String (Either Boolean JSONSchema)
decodeAdditionalProperties Nothing = Right $ Left true
decodeAdditionalProperties (Just j)
    | isBoolean j = do
        b <- decodeJson j
        pure $ Left b
    | otherwise = do
        js <- decodeJson j
        pure $ Right js

instance decodeJsonSchema :: DecodeJson JSONSchema where
    decodeJson j = do
        obj <- decodeJson j
        definitions <- obj .?? "definitions"
        ref <- obj .?? "$ref"
        types <- decodeTypes $ SM.lookup "type" obj
        oneOf <- obj .?? "oneOf"
        properties <- obj .?? "properties"
        additionalProperties <- decodeAdditionalProperties $ SM.lookup "additionalProperties" obj
        items <- obj .?? "items"
        required <- obj .?? "required"
        title <- obj .?? "title"
        pure $ JSONSchema { definitions, ref, types, oneOf, properties, additionalProperties, items, required, title }

lookupRef :: JSONSchema -> List String -> JSONSchema -> Either String JSONSchema
lookupRef root ref local@(JSONSchema { definitions }) =
    case ref of
    L.Nil -> Right local
    "#" : rest -> lookupRef root rest root
    "definitions" : name : rest ->
        case definitions of
        Just sm ->
            case SM.lookup name sm of
            Just js -> lookupRef root rest js
            Nothing -> Left "Reference not found"
        Nothing -> Left "Definitions not found"
    _ -> Left "Reference not supported"

toIRAndUnify :: forall a f. Foldable f => (a -> IR (Either String IRType)) -> f a -> IR (Either String IRType)
toIRAndUnify toIR l = do
    irsAndErrors <- mapM toIR $ L.fromFoldable l
    let irsOrError = foldError irsAndErrors
    either (\e -> pure $ Left e) (\irs -> Right <$> foldM unifyTypes IRNothing irs) irsOrError

jsonSchemaToIR :: JSONSchema -> Either String String -> JSONSchema -> IR (Either String IRType)
jsonSchemaToIR root name schema@(JSONSchema { definitions, ref, types, oneOf, properties, additionalProperties, items, required })
    | Just (JSONSchemaRef r) <- ref =
        case lookupRef root (NEL.toList r) schema of
        Left err -> pure $ Left err
        Right js -> jsonSchemaToIR root (Left $ NEL.last r) js
    | Just (Left jt) <- types =
        jsonTypeToIR root name jt schema
    | Just (Right jts) <- types =
        toIRAndUnify (\jt -> jsonTypeToIR root name jt schema) jts
    | Just jss <- oneOf =
        toIRAndUnify (jsonSchemaToIR root name) jss
    | otherwise =
        pure $ Right IRNothing

jsonSchemaListToIR :: forall t. Traversable t => Either String String -> t JSONSchema -> IR (Either String IRType)
jsonSchemaListToIR name l = do
    errorOrTypeList <- mapM (\js -> jsonSchemaToIR js name js) l
    case foldError errorOrTypeList of
        Left err -> pure $ Left err
        Right irTypes -> Right <$> unifyMultipleTypes irTypes

jsonTypeToIR :: JSONSchema -> Either String String -> JSONType -> JSONSchema -> IR (Either String IRType)
jsonTypeToIR root name jsonType (JSONSchema schema) =
    case jsonType of
    JSONObject ->
        case schema.properties of
        Just sm -> do
            propsAndErrorsWrong :: List _ <- SM.toUnfoldable <$> mapStrMapM (\n -> jsonSchemaToIR root $ Right n) sm
            let propsOrError = M.fromFoldable <$> (foldError $ map raiseTuple propsAndErrorsWrong)
            let required = maybe S.empty S.fromFoldable schema.required
            let title = maybe name Left schema.title
            nulledPropsOrError <- either (\x -> pure $ Left x) (\x -> Right <$> mapMapM (\n -> if S.member n required then pure else unifyTypes IRNull) x) propsOrError
            classFromPropsOrError title nulledPropsOrError
        Nothing ->
            case schema.additionalProperties of
            Left true ->
                pure $ Right $ IRMap IRNothing
            Left false ->
                pure $ Right $ IRNothing
            Right js -> do
                irOrError <- jsonSchemaToIR root singularName js
                pure $ either Left (\ir -> Right $ IRMap ir) irOrError
    JSONArray ->
        case schema.items of
        Just js -> do
            itemIROrError <- (jsonSchemaToIR root singularName) js
            pure $ either Left (\ir -> Right $ IRArray ir) itemIROrError
        Nothing -> pure $ Right $ IRArray IRNothing
    JSONBoolean -> pure $ Right IRBool
    JSONString -> pure $ Right IRString
    JSONNull -> pure $ Right IRNull
    JSONInteger -> pure $ Right IRInteger
    JSONNumber -> pure $ Right IRDouble
    where
        classFromPropsOrError :: Either String String -> Either String (Map String IRType) -> IR (Either String IRType)
        classFromPropsOrError title =
            case _ of
            Left err -> pure $ Left err
            Right props -> do
                Right <$> (addClass $ makeClass title props)
        raiseTuple :: Tuple String (Either String IRType) -> Either String (Tuple String IRType)
        raiseTuple (Tuple k irOrError) =
            either Left (\ir -> Right $ Tuple k ir) irOrError
        singularName = Right $ singular $ either id id name

forbiddenNames :: Array String
forbiddenNames = []

renderer :: Renderer
renderer =
    { name: "JSON Schema"
    , aceMode: "json"
    , extension: "schema"
    , doc: jsonSchemaDoc
    , transforms:
        { nameForClass: simpleNamer nameForClass
        , unionName: Nothing
        , unionPredicate: Nothing
        , nextName: \s -> "Other" <> s
        , forbiddenNames
        , topLevelName: simpleNamer jsonNameStyle -- FIXME: put title on top levels, too
        }
    }

legalize :: String -> String
legalize s =
    String.fromCharArray $ map (\c -> if isLegal c then c else '_') (String.toCharArray s)
    where
        isLegal c =
            let cc = Char.toCharCode c
            in cc >= 32 && cc < 128 && c /= '/'

jsonNameStyle :: String -> String
jsonNameStyle =
    legalize >>> camelCase >>> capitalize

nameForClass :: IRClassData -> String
nameForClass (IRClassData { names }) = jsonNameStyle $ combineNames names

unionName :: List String -> String
unionName s =
    L.sort s
    <#> jsonNameStyle
    # intercalate "Or"

typeStrMap :: String -> Doc (StrMap Json)
typeStrMap s = pure $ SM.insert "type" (fromString s) SM.empty

typeJson :: String -> Doc Json
typeJson s = fromObject <$> typeStrMap s

strMapForType :: IRType -> Doc (StrMap Json)
strMapForType t =
    case t of
    IRNothing -> pure $ SM.empty
    IRNull -> typeStrMap "null"
    IRInteger -> typeStrMap "integer"
    IRDouble -> typeStrMap "number"
    IRBool -> typeStrMap "boolean"
    IRString -> typeStrMap "string"
    IRArray a -> do
        itemType <- jsonForType a
        sm <- typeStrMap "array"
        pure $ SM.insert "items" itemType sm
    IRClass i -> do
        name <- lookupClassName i
        pure $ SM.insert "$ref" (fromString $ "#/definitions/" <> name) SM.empty
    IRMap m -> do
        propertyType <- jsonForType m
        sm <- typeStrMap "object"
        pure $ SM.insert "additionalProperties" propertyType sm
    IRUnion ur -> do
        types <- mapM jsonForType $ L.fromFoldable $ unionToSet ur
        let typesJson = fromArray $ A.fromFoldable types
        pure $ SM.insert "oneOf" typesJson SM.empty

jsonForType :: IRType -> Doc Json
jsonForType t = do
    sm <- strMapForType t
    pure $ fromObject sm

strMapForOneOfTypes :: List IRType -> Doc (StrMap Json)
strMapForOneOfTypes L.Nil = pure $ SM.empty
strMapForOneOfTypes (t : L.Nil) = strMapForType t
strMapForOneOfTypes typeList = do
    objList <- mapM jsonForType typeList
    pure $ SM.insert "oneOf" (fromArray $ A.fromFoldable objList) SM.empty

definitionForClass :: Tuple Int IRClassData -> Doc (Tuple String Json)
definitionForClass (Tuple i (IRClassData { properties })) = do
    className <- lookupClassName i
    let sm = SM.insert "additionalProperties" (fromBoolean false) $ SM.insert "type" (fromString "object") SM.empty
    propsMap <- mapMapM (const jsonForType) properties
    let requiredProps = A.fromFoldable $ map fromString $ M.keys $ M.filter (\t -> not $ canBeNull t) properties
    let propsSM = SM.fromFoldable $ (M.toUnfoldable propsMap :: List _)
    let withProperties = SM.insert "properties" (fromObject propsSM) sm
    let withRequired = SM.insert "required" (fromArray requiredProps) withProperties
    let withTitle = SM.insert "title" (fromString className) withRequired
    pure $ Tuple className $ fromObject withTitle

irToJson :: Doc Json
irToJson = do
    classes <- getClasses
    definitions <- fromObject <$> SM.fromFoldable <$> mapM definitionForClass classes
    -- FIXME: give a title to top-levels, too
    topLevel <- strMapForOneOfTypes =<< M.values <$> getTopLevels
    let sm = SM.insert "definitions" definitions topLevel
    pure $ fromObject sm

jsonSchemaDoc :: Doc Unit
jsonSchemaDoc = do
    json <- irToJson
    line $ stringifyWithSpace "    " json
