;;;; schema-parser.lisp - OpenAPI schema parsing and CL type generation
;;;;
;;;; Parses OpenAPI/Swagger 2.0 JSON Schema definitions into structured
;;;; Common Lisp representations. Handles:
;;;;   - Primitive types (string, integer, number, boolean)
;;;;   - Compound types (object, array)
;;;;   - Enumerations
;;;;   - Format specifiers (int32, int64, float, double, date-time)
;;;;   - Required/optional field tracking
;;;;   - Nested object schemas (inline in response definitions)
;;;;   - $ref resolution for shared definitions
;;;;
;;;; The parser produces schema-definition structs that can be used by the
;;;; code generator to create type definitions, validation functions, and
;;;; documentation.
;;;;
;;;; Design: All functions are pure - they take parsed JSON (hash-tables
;;;; from jzon) and return schema structs. No I/O or side effects.

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Schema representation structures
;;; ---------------------------------------------------------------------------

(defstruct (schema-definition (:constructor make-schema-definition)
                              (:print-function print-schema-definition))
  "Represents a parsed OpenAPI schema definition.

Slots:
  NAME: Schema identifier (string, e.g., \"get_characters_character_id_ok\")
  TYPE: OpenAPI type keyword (:object :array :string :integer :number :boolean)
  FORMAT: Optional format specifier (:int32 :int64 :float :double :date-time)
  DESCRIPTION: Human-readable description from the spec
  PROPERTIES: For objects - list of property-definition structs
  REQUIRED-FIELDS: List of required property name strings
  ITEMS-SCHEMA: For arrays - schema-definition of array element type
  ENUM-VALUES: For enums - list of allowed values
  MIN-VALUE: Numeric minimum constraint
  MAX-VALUE: Numeric maximum constraint
  MIN-ITEMS: Array minimum items constraint
  MAX-ITEMS: Array maximum items constraint
  UNIQUE-ITEMS-P: Whether array items must be unique
  REF: Original $ref string if this was a reference
  CL-TYPE: Generated Common Lisp type specifier"
  (name nil :type (or null string))
  (type nil :type (or null keyword))
  (format nil :type (or null keyword))
  (description nil :type (or null string))
  (properties nil :type list)
  (required-fields nil :type list)
  (items-schema nil :type (or null schema-definition))
  (enum-values nil :type list)
  (min-value nil :type (or null number))
  (max-value nil :type (or null number))
  (min-items nil :type (or null integer))
  (max-items nil :type (or null integer))
  (unique-items-p nil :type boolean)
  (ref nil :type (or null string))
  (cl-type nil))

(defun print-schema-definition (schema stream depth)
  "Print a schema-definition in a readable format."
  (declare (ignore depth))
  (print-unreadable-object (schema stream :type t)
    (format stream "~A ~A~@[ ~A~]~@[ (~D props)~]"
            (or (schema-definition-name schema) "anonymous")
            (or (schema-definition-type schema) :unknown)
            (schema-definition-format schema)
            (when (schema-definition-properties schema)
              (length (schema-definition-properties schema))))))

(defstruct (property-definition (:constructor make-property-definition)
                                (:print-function print-property-definition))
  "Represents a single property within an object schema.

Slots:
  NAME: Property name as it appears in JSON (string)
  CL-NAME: Lispified property name (symbol or string)
  SCHEMA: The property's type schema (schema-definition)
  REQUIRED-P: Whether this property is required
  DESCRIPTION: Human-readable description"
  (name nil :type (or null string))
  (cl-name nil)
  (schema nil :type (or null schema-definition))
  (required-p nil :type boolean)
  (description nil :type (or null string)))

(defun print-property-definition (prop stream depth)
  "Print a property-definition in a readable format."
  (declare (ignore depth))
  (print-unreadable-object (prop stream :type t)
    (format stream "~A ~A~:[~; REQUIRED~]"
            (property-definition-name prop)
            (when (property-definition-schema prop)
              (schema-definition-type (property-definition-schema prop)))
            (property-definition-required-p prop))))

;;; ---------------------------------------------------------------------------
;;; JSON type string to keyword mapping
;;; ---------------------------------------------------------------------------

(defun json-type->keyword (type-string)
  "Convert an OpenAPI type string to a keyword symbol.

TYPE-STRING: OpenAPI type (\"string\", \"integer\", \"number\", \"boolean\", \"object\", \"array\")

Returns a keyword symbol (:STRING, :INTEGER, etc.) or NIL for unknown types.

Example:
  (json-type->keyword \"integer\") => :INTEGER
  (json-type->keyword \"object\") => :OBJECT"
  (when type-string
    (let ((type (string-downcase (string type-string))))
      (cond
        ((string= type "string") :string)
        ((string= type "integer") :integer)
        ((string= type "number") :number)
        ((string= type "boolean") :boolean)
        ((string= type "object") :object)
        ((string= type "array") :array)
        (t (intern (string-upcase type) :keyword))))))

(defun json-format->keyword (format-string)
  "Convert an OpenAPI format string to a keyword symbol.

FORMAT-STRING: OpenAPI format (\"int32\", \"int64\", \"float\", \"double\", \"date-time\")

Returns a keyword symbol or NIL.

Example:
  (json-format->keyword \"int32\") => :INT32
  (json-format->keyword \"date-time\") => :DATE-TIME"
  (when format-string
    (intern (string-upcase (substitute #\- #\_ (string format-string)))
            :keyword)))

;;; ---------------------------------------------------------------------------
;;; Schema parsing - core
;;; ---------------------------------------------------------------------------

(defun parse-schema (schema-hash &key name)
  "Parse an OpenAPI schema hash-table into a schema-definition struct.

SCHEMA-HASH: A hash-table from jzon representing a JSON Schema object
NAME: Optional name to assign to this schema

Returns a SCHEMA-DEFINITION struct.

This is the main entry point for schema parsing. Handles all OpenAPI types
including nested objects, arrays, enums, and $ref references.

Example:
  ;; Parse a simple integer schema
  (parse-schema #{\"type\" \"integer\" \"format\" \"int32\"})
  => #<SCHEMA-DEFINITION anonymous INTEGER INT32>"
  (when (null schema-hash)
    (return-from parse-schema
      (make-schema-definition :name name :type :unknown)))
  ;; Handle $ref - just record it, resolution happens at a higher level
  (let ((ref (ht-get schema-hash "$ref")))
    (when ref
      (return-from parse-schema
        (make-schema-definition
         :name name
         :ref ref
         :description (format nil "Reference to ~A" ref)))))
  (let* ((type-str (ht-get schema-hash "type"))
         (type-kw (json-type->keyword type-str))
         (format-str (ht-get schema-hash "format"))
         (format-kw (json-format->keyword format-str))
         (description (ht-get schema-hash "description"))
         (title (ht-get schema-hash "title"))
         (schema-name (or name title)))
    (case type-kw
      (:object
       (parse-object-schema schema-hash :name schema-name :description description))
      (:array
       (parse-array-schema schema-hash :name schema-name :description description))
      (otherwise
       (parse-primitive-schema schema-hash
                               :name schema-name
                               :type type-kw
                               :format format-kw
                               :description description)))))

(defun parse-object-schema (schema-hash &key name description)
  "Parse an object-type schema with properties.

SCHEMA-HASH: Hash-table representing the object schema
NAME: Optional name for this schema
DESCRIPTION: Optional description

Returns a SCHEMA-DEFINITION with TYPE :OBJECT and populated PROPERTIES."
  (let* ((props-hash (ht-get schema-hash "properties"))
         (required-list (ht-get-list schema-hash "required"))
         (properties (when props-hash
                       (parse-properties props-hash required-list))))
    (make-schema-definition
     :name name
     :type :object
     :description description
     :properties properties
     :required-fields required-list
     :cl-type (generate-object-cl-type name properties))))

(defun parse-array-schema (schema-hash &key name description)
  "Parse an array-type schema with items definition.

SCHEMA-HASH: Hash-table representing the array schema
NAME: Optional name for this schema
DESCRIPTION: Optional description

Returns a SCHEMA-DEFINITION with TYPE :ARRAY and populated ITEMS-SCHEMA."
  (let* ((items-hash (ht-get schema-hash "items"))
         (items-schema (when items-hash
                         (parse-schema items-hash :name (format nil "~@[~A-~]item" name))))
         (min-items (ht-get schema-hash "minItems"))
         (max-items (ht-get schema-hash "maxItems"))
         (unique-items (ht-get schema-hash "uniqueItems")))
    (make-schema-definition
     :name name
     :type :array
     :description description
     :items-schema items-schema
     :min-items (when min-items (truncate min-items))
     :max-items (when max-items (truncate max-items))
     :unique-items-p (and unique-items (not (eq unique-items :false)) t)
     :cl-type (generate-array-cl-type items-schema))))

(defun parse-primitive-schema (schema-hash &key name type format description)
  "Parse a primitive-type schema (string, integer, number, boolean).

SCHEMA-HASH: Hash-table representing the schema
NAME: Optional name
TYPE: Keyword type (:STRING, :INTEGER, :NUMBER, :BOOLEAN)
FORMAT: Optional format keyword (:INT32, :INT64, :FLOAT, :DOUBLE, :DATE-TIME)
DESCRIPTION: Optional description

Returns a SCHEMA-DEFINITION with appropriate CL-TYPE."
  (let* ((enum-values (ht-get-list schema-hash "enum"))
         (minimum (ht-get schema-hash "minimum"))
         (maximum (ht-get schema-hash "maximum")))
    (make-schema-definition
     :name name
     :type (or type :unknown)
     :format format
     :description description
     :enum-values enum-values
     :min-value minimum
     :max-value maximum
     :cl-type (generate-primitive-cl-type type format enum-values minimum maximum))))

;;; ---------------------------------------------------------------------------
;;; Property parsing
;;; ---------------------------------------------------------------------------

(defun parse-properties (properties-hash required-list)
  "Parse an object's properties hash-table into a list of property-definitions.

PROPERTIES-HASH: Hash-table mapping property names to their schema hash-tables
REQUIRED-LIST: List of property name strings that are required

Returns a list of PROPERTY-DEFINITION structs, sorted alphabetically by name."
  (let ((properties '()))
    (maphash
     (lambda (prop-name prop-schema-hash)
       (let* ((required-p (member prop-name required-list :test #'string=))
              (prop-schema (parse-schema prop-schema-hash :name prop-name))
              (prop-description (or (ht-get prop-schema-hash "description")
                                    (schema-definition-description prop-schema))))
         (push (make-property-definition
                :name prop-name
                :cl-name (json-name->lisp-name prop-name)
                :schema prop-schema
                :required-p (and required-p t)
                :description prop-description)
               properties)))
     properties-hash)
    ;; Sort for deterministic output
    (sort properties #'string< :key #'property-definition-name)))

;;; ---------------------------------------------------------------------------
;;; Common Lisp type generation
;;; ---------------------------------------------------------------------------

(defun generate-primitive-cl-type (type format enum-values minimum maximum)
  "Generate a Common Lisp type specifier for a primitive OpenAPI type.

TYPE: Keyword type (:STRING :INTEGER :NUMBER :BOOLEAN)
FORMAT: Optional format keyword
ENUM-VALUES: Optional list of allowed values
MINIMUM: Optional numeric minimum
MAXIMUM: Optional numeric maximum

Returns a Common Lisp type specifier form.

Example:
  (generate-primitive-cl-type :integer :int32 nil nil nil) => '(signed-byte 32)
  (generate-primitive-cl-type :string nil '(\"buy\" \"sell\") nil nil)
    => '(member \"buy\" \"sell\")"
  (cond
    ;; Enum types
    (enum-values
     `(member ,@enum-values))
    ;; Integer types with format
    ((eq type :integer)
     (case format
       (:int32 (if (and minimum maximum)
                   `(integer ,(truncate minimum) ,(truncate maximum))
                   '(signed-byte 32)))
       (:int64 (if (and minimum maximum)
                    `(integer ,(truncate minimum) ,(truncate maximum))
                    '(signed-byte 64)))
       (otherwise (if (and minimum maximum)
                      `(integer ,(truncate minimum) ,(truncate maximum))
                      'integer))))
    ;; Number types with format
    ((eq type :number)
     (case format
       (:float 'single-float)
       (:double 'double-float)
       (otherwise 'number)))
    ;; String types
    ((eq type :string)
     (case format
       (:date-time 'string)  ; Could be local-time:timestamp in future
       (otherwise 'string)))
    ;; Boolean
    ((eq type :boolean) 'boolean)
    ;; Unknown
    (t t)))

(defun generate-object-cl-type (name properties)
  "Generate a Common Lisp type specifier for an object schema.
For objects, we use a hash-table type since ESI returns JSON objects.

NAME: Schema name (used as documentation)
PROPERTIES: List of property-definition structs

Returns a type specifier."
  (declare (ignore name properties))
  'hash-table)

(defun generate-array-cl-type (items-schema)
  "Generate a Common Lisp type specifier for an array schema.

ITEMS-SCHEMA: Schema-definition for the array's element type

Returns a type specifier."
  (declare (ignore items-schema))
  ;; jzon parses JSON arrays as vectors
  '(or vector list))

;;; ---------------------------------------------------------------------------
;;; Name transformation
;;; ---------------------------------------------------------------------------

(defun json-name->lisp-name (json-name)
  "Convert a JSON property name to an idiomatic Common Lisp symbol name.

JSON-NAME: String property name from JSON (e.g., \"character_id\", \"is_buy_order\")

Returns a keyword symbol suitable for use as a Lisp accessor name.

Example:
  (json-name->lisp-name \"character_id\") => :CHARACTER-ID
  (json-name->lisp-name \"is_buy_order\") => :IS-BUY-ORDER"
  (intern (string-upcase (substitute #\- #\_ json-name)) :keyword))

(defun operation-id->function-name (operation-id)
  "Convert an OpenAPI operationId to a Common Lisp function name string.

OPERATION-ID: String operationId (e.g., \"get_characters_character_id\")

Returns a hyphenated lowercase string suitable for a Lisp function name.

Example:
  (operation-id->function-name \"get_characters_character_id\")
    => \"get-characters-character-id\"
  (operation-id->function-name \"post_characters_affiliation\")
    => \"post-characters-affiliation\""
  (string-downcase (substitute #\- #\_ operation-id)))

;;; ---------------------------------------------------------------------------
;;; Hash-table access utilities (for jzon-parsed JSON)
;;; ---------------------------------------------------------------------------

(defun ht-get (hash-table key &optional default)
  "Safely get a value from a hash-table, returning DEFAULT if not found or if
HASH-TABLE is NIL.

HASH-TABLE: A hash-table (or NIL)
KEY: String key to look up
DEFAULT: Value to return if key not found (default: NIL)

Returns the value associated with KEY, or DEFAULT."
  (if (hash-table-p hash-table)
      (gethash key hash-table default)
      default))

(defun ht-get-list (hash-table key)
  "Get a value from a hash-table and coerce it to a list.
Handles jzon's representation of JSON arrays as vectors.

HASH-TABLE: A hash-table (or NIL)
KEY: String key to look up

Returns a list (empty list if key not found or value is not a sequence)."
  (let ((val (ht-get hash-table key)))
    (cond
      ((null val) nil)
      ((listp val) val)
      ((vectorp val) (coerce val 'list))
      (t (list val)))))

;;; ---------------------------------------------------------------------------
;;; $ref resolution
;;; ---------------------------------------------------------------------------

(defun resolve-ref (ref-string)
  "Extract the definition name from a JSON $ref string.

REF-STRING: A $ref path like \"#/definitions/bad_request\" or \"#/parameters/character_id\"

Returns two values: the definition name and the ref section.

Example:
  (resolve-ref \"#/definitions/bad_request\") => \"bad_request\", \"definitions\"
  (resolve-ref \"#/parameters/character_id\") => \"character_id\", \"parameters\""
  (when ref-string
    (let ((parts (cl-ppcre:split "/" ref-string)))
      ;; #/definitions/name or #/parameters/name
      (when (>= (length parts) 3)
        (values (third parts) (second parts))))))

(defun resolve-schema-ref (ref-string spec-hash)
  "Resolve a $ref string to the actual schema hash-table from the spec.

REF-STRING: A $ref path like \"#/definitions/bad_request\"
SPEC-HASH: The full OpenAPI specification hash-table

Returns the resolved schema hash-table, or NIL if not found."
  (multiple-value-bind (name section) (resolve-ref ref-string)
    (when (and name section)
      (let ((section-hash (ht-get spec-hash section)))
        (when section-hash
          (ht-get section-hash name))))))

(defun resolve-parameter-ref (ref-string spec-hash)
  "Resolve a parameter $ref to the actual parameter hash-table.

REF-STRING: A $ref path like \"#/parameters/character_id\"
SPEC-HASH: The full OpenAPI specification hash-table

Returns the resolved parameter hash-table, or NIL."
  (resolve-schema-ref ref-string spec-hash))

;;; ---------------------------------------------------------------------------
;;; Schema validation
;;; ---------------------------------------------------------------------------

(defun validate-schema (schema)
  "Validate a schema-definition for completeness and consistency.

SCHEMA: A schema-definition struct to validate

Returns two values:
  1. T if valid, NIL otherwise
  2. List of validation issue strings (empty if valid)"
  (let ((issues '()))
    (unless (schema-definition-type schema)
      (push "Schema has no type" issues))
    (when (eq (schema-definition-type schema) :object)
      (unless (schema-definition-properties schema)
        (push "Object schema has no properties" issues)))
    (when (eq (schema-definition-type schema) :array)
      (unless (schema-definition-items-schema schema)
        (push "Array schema has no items definition" issues)))
    (values (null issues) (nreverse issues))))

(defun schema-summary (schema &optional (indent 0))
  "Generate a human-readable summary of a schema-definition.

SCHEMA: A schema-definition struct
INDENT: Indentation level for nested output

Returns a string describing the schema structure."
  (let ((prefix (make-string (* indent 2) :initial-element #\Space)))
    (with-output-to-string (s)
      (format s "~A~A: ~A" prefix
              (or (schema-definition-name schema) "anonymous")
              (schema-definition-type schema))
      (when (schema-definition-format schema)
        (format s " (~A)" (schema-definition-format schema)))
      (when (schema-definition-enum-values schema)
        (format s " enum:~{~A~^|~}" (schema-definition-enum-values schema)))
      (when (schema-definition-description schema)
        (format s " - ~A"
                (let ((desc (schema-definition-description schema)))
                  (if (> (length desc) 60)
                      (concatenate 'string (subseq desc 0 57) "...")
                      desc))))
      (when (and (eq (schema-definition-type schema) :object)
                 (schema-definition-properties schema))
        (dolist (prop (schema-definition-properties schema))
          (format s "~%~A"
                  (schema-summary (property-definition-schema prop)
                                  (1+ indent))))))))
