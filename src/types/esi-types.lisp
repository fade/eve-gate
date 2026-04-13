;;;; esi-types.lisp - Eve Online entity type definitions for eve-gate
;;;;
;;;; Defines Common Lisp types for all primary EVE Online entity identifiers
;;;; used throughout the ESI API. Each entity type includes:
;;;;   - deftype definitions for compile-time type checking
;;;;   - Predicate functions for runtime validation
;;;;   - Range constants reflecting ESI/SDE constraints
;;;;
;;;; EVE Online IDs are 32-bit signed integers with positive values (1+).
;;;; Some IDs (structure-id, fleet-id, item-id) use 64-bit integers.
;;;; These ranges are enforced by the type definitions.
;;;;
;;;; Design: Types are defined as subtypes of INTEGER with range constraints.
;;;; Predicate functions provide fast runtime checks. All predicates follow
;;;; the Common Lisp convention of -p suffix.

(in-package #:eve-gate.types)

;;; ---------------------------------------------------------------------------
;;; Range constants
;;; ---------------------------------------------------------------------------

(defconstant +min-esi-id+ 1
  "Minimum valid ESI entity ID. All IDs are positive integers starting at 1.")

(defconstant +max-int32+ 2147483647
  "Maximum value for ESI 32-bit integer IDs.")

(defconstant +max-int64+ 9223372036854775807
  "Maximum value for ESI 64-bit integer IDs (structures, fleets, items).")

;;; ---------------------------------------------------------------------------
;;; Core entity ID types — 32-bit positive integers
;;; ---------------------------------------------------------------------------
;;; These cover the primary entities that are referenced by ESI endpoints.
;;; All use int32 format in the OpenAPI spec with minimum value of 1.

(deftype esi-id ()
  "Base type for all ESI entity identifiers: positive 32-bit integers."
  '(integer 1 #.+max-int32+))

(deftype character-id ()
  "EVE Online character identifier.
Characters are player-controlled entities with IDs in the int32 range.
Character IDs are assigned sequentially and currently range from ~90000000 to ~2120000000.

Example valid values: 95465499, 2112625428"
  '(integer 1 #.+max-int32+))

(deftype corporation-id ()
  "EVE Online corporation identifier.
Corporations are the primary group organizational unit.
NPC corporations use lower ID ranges; player corporations use higher ranges.

Example valid values: 98000001, 109299958"
  '(integer 1 #.+max-int32+))

(deftype alliance-id ()
  "EVE Online alliance identifier.
Alliances are coalitions of corporations.

Example valid values: 99000001, 1354830081"
  '(integer 1 #.+max-int32+))

(deftype type-id ()
  "EVE Online item/ship type identifier.
Types are defined in the Static Data Export (SDE) and range from 0 to ~65000+.
Some special types may use higher IDs.

Example valid values: 587 (Rifter), 670 (Capsule)"
  '(integer 0 #.+max-int32+))

(deftype region-id ()
  "EVE Online region identifier.
Regions are large areas of space. Known regions range from 10000001 to 11000033.
Includes k-space, wormhole space, and Abyssal deadspace regions.

Example valid values: 10000002 (The Forge), 10000043 (Domain)"
  '(integer 1 #.+max-int32+))

(deftype constellation-id ()
  "EVE Online constellation identifier.
Constellations are groups of solar systems within a region.

Example valid values: 20000020 (Kimotoro)"
  '(integer 1 #.+max-int32+))

(deftype solar-system-id ()
  "EVE Online solar system identifier.
Solar systems are the primary navigable locations. Known systems range
from 30000001 to 31002504, with additional wormhole and Abyssal systems.

Example valid values: 30000142 (Jita), 30002187 (Amarr)"
  '(integer 1 #.+max-int32+))

(deftype station-id ()
  "EVE Online station identifier.
NPC stations have IDs in the range 60000000-61000000.
Player-owned stations (legacy) may be outside this range.

Example valid values: 60003760 (Jita IV - Moon 4 - Caldari Navy Assembly Plant)"
  '(integer 1 #.+max-int32+))

(deftype planet-id ()
  "EVE Online planet identifier.

Example valid values: 40009082"
  '(integer 1 #.+max-int32+))

(deftype moon-id ()
  "EVE Online moon identifier.

Example valid values: 40009083"
  '(integer 1 #.+max-int32+))

(deftype stargate-id ()
  "EVE Online stargate identifier."
  '(integer 1 #.+max-int32+))

(deftype asteroid-belt-id ()
  "EVE Online asteroid belt identifier."
  '(integer 1 #.+max-int32+))

(deftype market-group-id ()
  "EVE Online market group identifier."
  '(integer 0 #.+max-int32+))

(deftype category-id ()
  "EVE Online inventory category identifier."
  '(integer 0 #.+max-int32+))

(deftype group-id ()
  "EVE Online inventory group identifier."
  '(integer 0 #.+max-int32+))

(deftype graphic-id ()
  "EVE Online graphic identifier."
  '(integer 0 #.+max-int32+))

(deftype dogma-attribute-id ()
  "EVE Online dogma attribute identifier."
  '(integer 0 #.+max-int32+))

(deftype dogma-effect-id ()
  "EVE Online dogma effect identifier."
  '(integer 0 #.+max-int32+))

(deftype war-id ()
  "EVE Online war identifier."
  '(integer 1 #.+max-int32+))

(deftype contract-id ()
  "EVE Online contract identifier."
  '(integer 1 #.+max-int32+))

(deftype killmail-id ()
  "EVE Online killmail identifier."
  '(integer 1 #.+max-int32+))

(deftype fitting-id ()
  "EVE Online fitting identifier."
  '(integer 1 #.+max-int32+))

(deftype schematic-id ()
  "EVE Online planetary interaction schematic identifier."
  '(integer 1 #.+max-int32+))

(deftype faction-id ()
  "EVE Online faction identifier.
Factions are NPC organizations. Known faction IDs include Caldari State (500001),
Minmatar Republic (500002), etc."
  '(integer 1 #.+max-int32+))

(deftype race-id ()
  "EVE Online race identifier."
  '(integer 1 #.+max-int32+))

(deftype bloodline-id ()
  "EVE Online bloodline identifier."
  '(integer 0 #.+max-int32+))

(deftype ancestry-id ()
  "EVE Online ancestry identifier."
  '(integer 0 #.+max-int32+))

;;; ---------------------------------------------------------------------------
;;; Extended entity ID types — 64-bit positive integers
;;; ---------------------------------------------------------------------------
;;; Some ESI entities use 64-bit IDs due to high creation rates or
;;; historical reasons.

(deftype structure-id ()
  "EVE Online player structure identifier.
Player structures (Citadels, Engineering Complexes, etc.) use 64-bit IDs
because they are created dynamically by players.

Example valid values: 1028858195912 (typical structure ID)"
  '(integer 1 #.+max-int64+))

(deftype fleet-id ()
  "EVE Online fleet identifier.
Fleet IDs are 64-bit because fleets are created and destroyed frequently.

Example valid values: 1234567890123"
  '(integer 1 #.+max-int64+))

(deftype item-id ()
  "EVE Online item instance identifier.
Individual item instances (assets, fitted modules, etc.) use 64-bit IDs
due to the enormous number of items in the game.

Example valid values: 1027847409779"
  '(integer 1 #.+max-int64+))

(deftype order-id ()
  "EVE Online market order identifier.
Market orders use 64-bit IDs."
  '(integer 1 #.+max-int64+))

(deftype transaction-id ()
  "EVE Online wallet transaction identifier."
  '(integer 1 #.+max-int64+))

(deftype journal-ref-id ()
  "EVE Online wallet journal reference identifier."
  '(integer 1 #.+max-int64+))

(deftype mail-id ()
  "EVE Online mail message identifier."
  '(integer 1 #.+max-int64+))

(deftype label-id ()
  "EVE Online label identifier (mail, contacts)."
  '(integer 0 #.+max-int64+))

(deftype event-id ()
  "EVE Online calendar event identifier."
  '(integer 1 #.+max-int64+))

(deftype observer-id ()
  "EVE Online mining observer identifier."
  '(integer 1 #.+max-int64+))

;;; ---------------------------------------------------------------------------
;;; Compound value types
;;; ---------------------------------------------------------------------------

(deftype killmail-hash ()
  "EVE Online killmail hash string.
Killmail hashes are 40-character hexadecimal strings used to authenticate
killmail data."
  '(and string (satisfies non-empty-string-p)))

(deftype esi-datasource ()
  "Valid ESI datasource identifiers."
  '(member :tranquility :singularity))

(deftype esi-language ()
  "Valid ESI language codes for localized content."
  '(member :en :de :fr :ja :ko :ru :zh))

(deftype order-type ()
  "Valid market order types."
  '(member :buy :sell :all))

(deftype route-flag ()
  "Valid route calculation flags."
  '(member :shortest :secure :insecure))

(deftype event-response ()
  "Valid calendar event response types."
  '(member :accepted :declined :tentative))

(deftype wallet-division ()
  "Valid corporation wallet division numbers."
  '(integer 1 7))

(deftype security-status ()
  "EVE Online security status range."
  '(float -10.0 10.0))

(deftype standing-value ()
  "EVE Online standing value range."
  '(float -10.0 10.0))

(deftype isk-amount ()
  "EVE Online ISK (currency) amount. Can be negative for expenses."
  'double-float)

;;; ---------------------------------------------------------------------------
;;; Predicate functions
;;; ---------------------------------------------------------------------------
;;; Runtime validation predicates. These are faster than TYPEP for hot paths
;;; and provide clear intent in generated code.

(declaim (inline esi-id-p))
(defun esi-id-p (value)
  "Return T if VALUE is a valid ESI 32-bit entity ID (positive integer <= 2^31-1).

VALUE: The value to test

Example:
  (esi-id-p 12345) => T
  (esi-id-p -1) => NIL
  (esi-id-p \"hello\") => NIL"
  (typep value 'esi-id))

(declaim (inline character-id-p))
(defun character-id-p (value)
  "Return T if VALUE is a valid character ID."
  (typep value 'character-id))

(declaim (inline corporation-id-p))
(defun corporation-id-p (value)
  "Return T if VALUE is a valid corporation ID."
  (typep value 'corporation-id))

(declaim (inline alliance-id-p))
(defun alliance-id-p (value)
  "Return T if VALUE is a valid alliance ID."
  (typep value 'alliance-id))

(declaim (inline type-id-p))
(defun type-id-p (value)
  "Return T if VALUE is a valid type ID."
  (typep value 'type-id))

(declaim (inline region-id-p))
(defun region-id-p (value)
  "Return T if VALUE is a valid region ID."
  (typep value 'region-id))

(declaim (inline constellation-id-p))
(defun constellation-id-p (value)
  "Return T if VALUE is a valid constellation ID."
  (typep value 'constellation-id))

(declaim (inline solar-system-id-p))
(defun solar-system-id-p (value)
  "Return T if VALUE is a valid solar system ID."
  (typep value 'solar-system-id))

(declaim (inline station-id-p))
(defun station-id-p (value)
  "Return T if VALUE is a valid station ID."
  (typep value 'station-id))

(declaim (inline structure-id-p))
(defun structure-id-p (value)
  "Return T if VALUE is a valid structure ID (64-bit)."
  (typep value 'structure-id))

(declaim (inline fleet-id-p))
(defun fleet-id-p (value)
  "Return T if VALUE is a valid fleet ID (64-bit)."
  (typep value 'fleet-id))

(declaim (inline item-id-p))
(defun item-id-p (value)
  "Return T if VALUE is a valid item instance ID (64-bit)."
  (typep value 'item-id))

(declaim (inline war-id-p))
(defun war-id-p (value)
  "Return T if VALUE is a valid war ID."
  (typep value 'war-id))

(declaim (inline contract-id-p))
(defun contract-id-p (value)
  "Return T if VALUE is a valid contract ID."
  (typep value 'contract-id))

(declaim (inline killmail-id-p))
(defun killmail-id-p (value)
  "Return T if VALUE is a valid killmail ID."
  (typep value 'killmail-id))

(declaim (inline order-id-p))
(defun order-id-p (value)
  "Return T if VALUE is a valid market order ID (64-bit)."
  (typep value 'order-id))

;;; ---------------------------------------------------------------------------
;;; Helper predicates for compound types
;;; ---------------------------------------------------------------------------

(defun non-empty-string-p (value)
  "Return T if VALUE is a non-empty string."
  (and (stringp value) (plusp (length value))))

(defun killmail-hash-p (value)
  "Return T if VALUE is a valid killmail hash (40-char hex string)."
  (and (stringp value)
       (= (length value) 40)
       (every (lambda (c)
                (or (digit-char-p c)
                    (find c "abcdef")))
              value)))

(defun esi-datasource-p (value)
  "Return T if VALUE is a valid ESI datasource keyword."
  (typep value 'esi-datasource))

(defun esi-language-p (value)
  "Return T if VALUE is a valid ESI language keyword."
  (typep value 'esi-language))

;;; ---------------------------------------------------------------------------
;;; ID type registry — maps parameter names to type predicates
;;; ---------------------------------------------------------------------------
;;; Used by the validation layer to automatically select the correct
;;; predicate based on the ESI parameter name from the OpenAPI spec.

(defparameter *esi-id-type-map*
  '(("character_id"     . character-id-p)
    ("corporation_id"   . corporation-id-p)
    ("alliance_id"      . alliance-id-p)
    ("type_id"          . type-id-p)
    ("region_id"        . region-id-p)
    ("constellation_id" . constellation-id-p)
    ("solar_system_id"  . solar-system-id-p)
    ("system_id"        . solar-system-id-p)
    ("station_id"       . station-id-p)
    ("structure_id"     . structure-id-p)
    ("fleet_id"         . fleet-id-p)
    ("item_id"          . item-id-p)
    ("war_id"           . war-id-p)
    ("contract_id"      . contract-id-p)
    ("killmail_id"      . killmail-id-p)
    ("fitting_id"       . fitting-id-p)
    ("planet_id"        . planet-id-p)
    ("moon_id"          . moon-id-p)
    ("stargate_id"      . stargate-id-p)
    ("asteroid_belt_id" . asteroid-belt-id-p)
    ("market_group_id"  . market-group-id-p)
    ("category_id"      . category-id-p)
    ("group_id"         . group-id-p)
    ("graphic_id"       . graphic-id-p)
    ("attribute_id"     . dogma-attribute-id-p)
    ("effect_id"        . dogma-effect-id-p)
    ("schematic_id"     . schematic-id-p)
    ("order_id"         . order-id-p)
    ("mail_id"          . mail-id-p)
    ("label_id"         . label-id-p)
    ("event_id"         . event-id-p)
    ("observer_id"      . observer-id-p)
    ("faction_id"       . faction-id-p))
  "Alist mapping ESI parameter names to their type predicate functions.
Used by the validation layer to automatically select appropriate ID validation
based on the parameter name from the OpenAPI spec.")

(defun esi-id-predicate-for (parameter-name)
  "Look up the type predicate function for an ESI parameter name.

PARAMETER-NAME: String, the ESI parameter name (e.g., \"character_id\")

Returns the predicate function symbol, or NIL if no specific predicate
is registered for this parameter name.

Example:
  (esi-id-predicate-for \"character_id\") => CHARACTER-ID-P
  (esi-id-predicate-for \"unknown\") => NIL"
  (cdr (assoc parameter-name *esi-id-type-map* :test #'string=)))

;;; ---------------------------------------------------------------------------
;;; Additional predicate helpers for less common types
;;; ---------------------------------------------------------------------------

(declaim (inline planet-id-p moon-id-p stargate-id-p asteroid-belt-id-p
                 market-group-id-p category-id-p group-id-p graphic-id-p
                 dogma-attribute-id-p dogma-effect-id-p schematic-id-p
                 fitting-id-p faction-id-p mail-id-p label-id-p
                 event-id-p observer-id-p))

(defun planet-id-p (value) (typep value 'planet-id))
(defun moon-id-p (value) (typep value 'moon-id))
(defun stargate-id-p (value) (typep value 'stargate-id))
(defun asteroid-belt-id-p (value) (typep value 'asteroid-belt-id))
(defun market-group-id-p (value) (typep value 'market-group-id))
(defun category-id-p (value) (typep value 'category-id))
(defun group-id-p (value) (typep value 'group-id))
(defun graphic-id-p (value) (typep value 'graphic-id))
(defun dogma-attribute-id-p (value) (typep value 'dogma-attribute-id))
(defun dogma-effect-id-p (value) (typep value 'dogma-effect-id))
(defun schematic-id-p (value) (typep value 'schematic-id))
(defun fitting-id-p (value) (typep value 'fitting-id))
(defun faction-id-p (value) (typep value 'faction-id))
(defun mail-id-p (value) (typep value 'mail-id))
(defun label-id-p (value) (typep value 'label-id))
(defun event-id-p (value) (typep value 'event-id))
(defun observer-id-p (value) (typep value 'observer-id))
