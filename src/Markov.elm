module Markov exposing
    ( Markov
    , empty
    , add, addList
    , phrase, PhraseSettings
    , encode, decode
    )

{-| Create a markov transition model of string inputs. This creates


# Types

@docs Markov


# Builders

@docs empty, fromList


# Modifiers

@docs add, addList


# Generation

@docs phrase, PhraseSettings


# Encoding and Decoding

@docs encode, decode

-}

import Array exposing (Array)
import Dict.Any exposing (AnyDict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import List.Extra
import List.Util
import Matrix exposing (Matrix)
import Matrix.Extra
import Random exposing (Generator)



{- A markov graph which represents the chance of transitioning from one element to another. The row is the 'from'
   element and the column is the 'to' element. Each row represents the transition counts for each of those elements.

   Note: Using this matrix library indices are given in (column, row) as per mathematical notation with (0, 0) on the
         top left.

   Example:

       a  b  c
     a 1  2  1
     b 3  2  5
     c 0  1  0

     a -> a = 1/4
     a -> b = 1/2
     a -> c = 1/4
-}


type Markov
    = Markov MarkovData


type alias MarkovData =
    { matrix : Matrix Int
    , alphabet : List Element
    , alphabetLookup : AnyDict Int Element Int
    }


type Element
    = Start
    | Element Char
    | End


elementComparable : Element -> Int
elementComparable e =
    case e of
        Start ->
            -2

        End ->
            -1

        Element char ->
            Char.toCode char



-- Builders


{-| Create an empty markov chain with no elements in it. This is needed to add further elements into it to start to
train the model.
-}
empty : List Char -> Markov
empty alphabet =
    let
        numElements =
            List.length alphabet

        alphabetWithTerminals =
            alphabet
                |> List.map Element
                |> (::) End
                |> (::) Start
    in
    Markov
        { matrix = Matrix.repeat numElements numElements 0
        , alphabet = alphabetWithTerminals
        , alphabetLookup =
            alphabetWithTerminals
                |> List.indexedMap (\i a -> ( a, i ))
                |> Dict.Any.fromList elementComparable
        }



-- Accessors


{-| Private: Method to convert a character to it's index within the matrix.
-}
charToIndex : Element -> Markov -> Maybe Int
charToIndex element (Markov model) =
    Dict.Any.get element model.alphabetLookup


{-| Private: Get the number of times this transition is located in the markov graph.
-}
get : Element -> Element -> Markov -> Maybe Int
get from to markov =
    case markov of
        Markov model ->
            case ( charToIndex from markov, charToIndex to markov ) of
                ( Just fromIndex, Just toIndex ) ->
                    Matrix.get toIndex fromIndex model.matrix
                        |> Result.toMaybe

                _ ->
                    Nothing



-- Modifiers


{-| Add a transition into the markov graph. If the character is not an uppercase or lowercase character or a digit then
the transition is not added.
-}
add : Element -> Element -> Markov -> Markov
add from to markov =
    let
        set value =
            Maybe.map2
                (\fromIndex toIndex ->
                    case markov of
                        Markov model ->
                            Markov
                                { model
                                    | matrix = Matrix.set toIndex fromIndex value model.matrix
                                }
                )
                (charToIndex from markov)
                (charToIndex to markov)
                |> Maybe.withDefault markov
    in
    get from to markov
        |> Maybe.map ((+) 1)
        |> Maybe.map set
        |> Maybe.withDefault markov


addList : List String -> Markov -> Markov
addList strings markov =
    strings
        |> List.map String.toList
        |> List.map (List.map Element)
        |> List.foldl addTransitionList markov


{-| Add a list of transitions.
-}
addTransitionList : List Element -> Markov -> Markov
addTransitionList trainingData markov =
    if List.isEmpty trainingData then
        markov

    else
        trainingData
            |> (::) Start
            |> (\beginning -> List.append beginning [ End ])
            |> List.Util.groupsOfTwo
            |> List.foldl (\( from, to ) -> add from to) markov



-- Generate


type alias PhraseSettings =
    { maxLength : Int
    }


phrase : PhraseSettings -> Markov -> Generator (List Char)
phrase settings markov =
    let
        phraseHelper : Int -> Element -> List Element -> Generator (List Element)
        phraseHelper remainingDepth prevElement accumulator =
            case remainingDepth of
                0 ->
                    Random.constant accumulator

                _ ->
                    Random.andThen
                        (\nextElement ->
                            case nextElement of
                                Element _ ->
                                    phraseHelper
                                        (remainingDepth - 1)
                                        nextElement
                                        (List.append accumulator [ nextElement ])

                                _ ->
                                    Random.constant accumulator
                        )
                        (genNextElement prevElement)

        genNextElement : Element -> Generator Element
        genNextElement prevElement =
            case transitionProbabilities prevElement markov of
                firstPossibility :: remainingPossibilities ->
                    Random.weighted firstPossibility remainingPossibilities

                [] ->
                    Random.constant End

        transitionProbabilities : Element -> Markov -> List ( Float, Element )
        transitionProbabilities from (Markov model) =
            charToIndex from (Markov model)
                |> Maybe.andThen (\row -> Result.toMaybe <| Matrix.getRow row model.matrix)
                |> Maybe.map Array.toList
                |> Maybe.map (List.map toFloat)
                |> Maybe.map (\row -> List.Extra.zip row model.alphabet)
                |> Maybe.withDefault [ ( 1, End ) ]

        cleanResults =
            List.filterMap
                (\e ->
                    case e of
                        Element a ->
                            Just a

                        _ ->
                            Nothing
                )
    in
    phraseHelper settings.maxLength Start []
        |> Random.map cleanResults



-- Encoding / Decoding


encode : Markov -> Value
encode (Markov { matrix, alphabet, alphabetLookup }) =
    let
        elementToString element =
            case element of
                Start ->
                    "start"

                End ->
                    "end"

                Element c ->
                    String.fromChar c
    in
    Encode.object
        [ ( "matrix"
          , Matrix.Extra.encode
                matrix
          )
        , ( "alphabet"
          , Encode.list
                (Encode.string << elementToString)
                alphabet
          )
        , ( "alphabetLookup"
          , Dict.Any.encode
                elementToString
                Encode.int
                alphabetLookup
          )
        ]


decode : Decoder Markov
decode =
    let
        stringToElement value =
            case value of
                "start" ->
                    Start

                "end" ->
                    End

                _ ->
                    value
                        |> String.toList
                        |> List.head
                        |> Maybe.withDefault ' '
                        |> Element
    in
    Decode.map3
        MarkovData
        (Decode.field "matrix"
            Matrix.Extra.decode
        )
        (Decode.field "alphabet" <|
            Decode.list (Decode.map stringToElement Decode.string)
        )
        (Decode.field "alphabetLookup" <|
            Dict.Any.decode
                (\keyString _ ->
                    stringToElement keyString
                )
                elementComparable
                Decode.int
        )
        |> Decode.map Markov
