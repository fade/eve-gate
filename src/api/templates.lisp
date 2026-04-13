;;;; templates.lisp - Template system for generating ESI API function forms
;;;;
;;;; Generates syntactically correct Common Lisp function definitions from
;;;; endpoint-definition structs. The template system produces DEFUN forms
;;;; that integrate with:
;;;;   - HTTP client for request execution
;;;;   - OAuth token manager for authenticated endpoints
;;;;   - Parameter validation from validation.lisp
;;;;   - Response parsing and type conversion
;;;;   - Comprehensive docstrings from OpenAPI descriptions
;;;;
;;;; Templates are composable: each aspect of a function (lambda list,
;;;; validation, request construction, response parsing, docstring) has
;;;; its own generator, and the top-level template assembles them.
;;;;
;;;; Design:
;;;;   - Pure functions: endpoint-definition -> Lisp form
;;;;   - No evaluation or side effects during generation
;;;;   - Generated forms are data (lists) that can be inspected,
;;;;     written to files, or compiled
;;;;   - Support for incremental regeneration via change detection
;;;;
;;;; Usage:
;;;;   (generate-endpoint-function-form endpoint)
;;;;     => (DEFUN get-characters-character-id (client character-id &key ...) ...)

(in-package #:eve-gate.api)

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(defparameter *generated-function-package* :eve-gate.api
  "Package in which generated function symbols will be interned.")

(defparameter *include-deprecation-warnings* t
  "When T, generated functions for deprecated endpoints include a deprecation warning.")

(defparameter *include-inline-validation* t
  "When T, generated functions include inline parameter validation checks.
When NIL, validation is performed by the generic validate-api-parameters function.")

(defparameter *default-page-limit* 10
  "Default maximum number of pages to fetch for paginated endpoints.")

;;; ---------------------------------------------------------------------------
;;; Top-level function form generation
;;; ---------------------------------------------------------------------------

(defun generate-endpoint-function-form (endpoint)
  "Generate a complete DEFUN form for an ESI endpoint.

ENDPOINT: An endpoint-definition struct from the spec processor

Returns a list representing a DEFUN form that can be compiled or written to a file.

The generated function:
  1. Accepts an HTTP client as first argument
  2. Takes required path parameters as positional arguments
  3. Takes optional/query parameters as keyword arguments
  4. Validates all parameters
  5. Constructs and executes the HTTP request
  6. Parses and returns the response

Example:
  (generate-endpoint-function-form
    (find-endpoint-by-id *spec* \"get_characters_character_id\"))
  => (DEFUN get-characters-character-id (client character-id &key datasource)
       \"Return public data about a character...\"
       ...)"
  (let* ((fn-name (intern (string-upcase (endpoint-definition-function-name endpoint))
                          *generated-function-package*))
         (lambda-list (generate-lambda-list endpoint))
         (docstring (generate-docstring endpoint))
         (body (generate-function-body endpoint)))
    `(defun ,fn-name ,lambda-list
       ,docstring
       ,@body)))

;;; ---------------------------------------------------------------------------
;;; Lambda list generation
;;; ---------------------------------------------------------------------------

(defun generate-lambda-list (endpoint)
  "Generate the lambda list for an endpoint function.

The lambda list structure is:
  (client <required-path-params>... &key <optional-params>... <query-params>... <body-param>)

CLIENT is always the first parameter (the HTTP client instance).
Path parameters that are required come next as positional arguments.
All query parameters and optional parameters are keyword arguments.
Body parameters (for POST/PUT) become keyword arguments.

For paginated endpoints, a :PAGE keyword is included (from the spec or added).
For authenticated endpoints, a :TOKEN keyword is added.

ENDPOINT: An endpoint-definition struct

Returns a list suitable as a DEFUN lambda list."
  (let* ((path-params (endpoint-definition-path-parameters endpoint))
         (query-params (endpoint-definition-query-parameters endpoint))
         (body-param (endpoint-definition-body-parameter endpoint))
         ;; Required path params become positional args
         (required-args (mapcar (lambda (p)
                                  (intern (symbol-name (parameter-definition-cl-name p))
                                          *generated-function-package*))
                                path-params))
         ;; Query params become keyword args with defaults
         (keyword-args (mapcar #'parameter-to-keyword-arg query-params))
         ;; Body param becomes a keyword arg
         (body-args (when body-param
                      (list (parameter-to-keyword-arg body-param))))
         ;; Check if page is already in query params (many ESI endpoints define it)
         (has-page-param (find "page" query-params
                               :key #'parameter-definition-name
                               :test #'string-equal))
         ;; Add pagination parameter only if not already present
         (pagination-args (when (and (endpoint-definition-paginated-p endpoint)
                                     (not has-page-param))
                            '((page nil))))
         ;; Add token parameter for authenticated endpoints
         (auth-args (when (endpoint-definition-requires-auth-p endpoint)
                      '((token nil)))))
    `(client ,@required-args
             &key ,@keyword-args
             ,@body-args
             ,@pagination-args
             ,@auth-args)))

(defun parameter-to-keyword-arg (param)
  "Convert a parameter-definition to a keyword argument specification.

PARAM: A parameter-definition struct

Returns a list (name default) suitable for a &key lambda list entry.

Example:
  For parameter 'order_type' with default 'buy':
  => (ORDER-TYPE \"buy\")"
  (let ((name (intern (symbol-name (parameter-definition-cl-name param))
                      *generated-function-package*))
        (default (parameter-definition-default-value param)))
    (if default
        (list name default)
        (list name nil))))

;;; ---------------------------------------------------------------------------
;;; Function body generation
;;; ---------------------------------------------------------------------------

(defun generate-function-body (endpoint)
  "Generate the body forms for an endpoint function.

Produces a LET form that:
  1. Deprecation warning (if applicable)
  2. Validates parameters
  3. Builds the request path with parameter substitution
  4. Constructs query parameters
  5. Executes the HTTP request
  6. Parses and returns the response

ENDPOINT: An endpoint-definition struct

Returns a list of forms for the function body."
  (let* ((method (endpoint-definition-method endpoint))
         (path-template (endpoint-definition-path endpoint))
         (path-params (endpoint-definition-path-parameters endpoint))
         (query-params (endpoint-definition-query-parameters endpoint))
         (body-param (endpoint-definition-body-parameter endpoint))
         (requires-auth (endpoint-definition-requires-auth-p endpoint))
         (paginated (endpoint-definition-paginated-p endpoint))
         (deprecated (endpoint-definition-deprecated-p endpoint))
         (forms '()))
    ;; Deprecation warning
    (when (and deprecated *include-deprecation-warnings*)
      (push (generate-deprecation-form endpoint) forms))
    ;; Validation forms
    (when *include-inline-validation*
      (let ((validation-forms (generate-validation-forms endpoint)))
        (when validation-forms
          (push validation-forms forms))))
    ;; Main request form
    (push (generate-request-form
           :method method
           :path-template path-template
           :path-params path-params
           :query-params query-params
           :body-param body-param
           :requires-auth requires-auth
           :paginated paginated
           :endpoint endpoint)
          forms)
    ;; Wrap in a single progn if multiple top-level forms
    (if (= (length forms) 1)
        forms
        (list `(progn ,@(nreverse forms))))))

(defun generate-deprecation-form (endpoint)
  "Generate a deprecation warning form for a deprecated endpoint.

ENDPOINT: An endpoint-definition struct

Returns a WARN form."
  (let ((alt-routes (endpoint-definition-alternate-routes endpoint)))
    `(warn 'esi-deprecation-warning
           :message ,(format nil "~A is deprecated"
                             (endpoint-definition-operation-id endpoint))
           :endpoint ,(endpoint-definition-path endpoint)
           :alternate-route ,(first alt-routes))))

(defun generate-validation-forms (endpoint)
  "Generate inline parameter validation forms.

ENDPOINT: An endpoint-definition struct

Returns a WHEN form wrapping all validation checks, or NIL if none needed."
  (let* ((all-params (append (endpoint-definition-path-parameters endpoint)
                             (endpoint-definition-query-parameters endpoint)
                             (when (endpoint-definition-body-parameter endpoint)
                               (list (endpoint-definition-body-parameter endpoint)))))
         (checks (remove nil (mapcar #'generate-validation-form all-params))))
    (when checks
      `(progn ,@checks))))

;;; ---------------------------------------------------------------------------
;;; Request construction
;;; ---------------------------------------------------------------------------

(defun generate-request-form (&key method path-template path-params query-params
                                    body-param requires-auth paginated endpoint)
  "Generate the HTTP request construction and execution form.

Returns a LET form that builds the URL, query params, and calls HTTP-REQUEST."
  (let* ((path-var 'request-path)
         (query-var 'query-params)
         (has-query-params (or query-params paginated))
         (path-subst-form (generate-path-substitution-form path-template path-params))
         (query-construction (generate-query-params-form query-params paginated))
         (request-call (generate-http-request-call
                        method path-var
                        (when has-query-params query-var)
                        body-param requires-auth))
         (response-handling (generate-response-handling endpoint)))
    `(let ((,path-var ,path-subst-form)
           ,@(when query-construction
               `((,query-var ,query-construction))))
       (let ((response ,request-call))
         ,response-handling))))

(defun generate-path-substitution-form (path-template path-params)
  "Generate a form that substitutes path parameter values into the URL template.

PATH-TEMPLATE: URL path template string with {param} placeholders
PATH-PARAMS: List of parameter-definition structs for path parameters

Returns a form that evaluates to the final URL path string."
  (if path-params
      (let ((substitutions
              (loop for param in path-params
                    collect `(cons ,(parameter-definition-name param)
                                   (princ-to-string
                                    ,(intern (symbol-name
                                              (parameter-definition-cl-name param))
                                             *generated-function-package*))))))
        `(substitute-path-parameters ,path-template (list ,@substitutions)))
      path-template))

(defun generate-query-params-form (query-params paginated)
  "Generate a form that builds the query parameters alist.

QUERY-PARAMS: List of parameter-definition structs for query parameters
PAGINATED: Whether to include a page parameter

Returns a form that evaluates to an alist, or NIL if no query params."
  (let* ((has-page-in-query (find "page" query-params
                                  :key #'parameter-definition-name
                                  :test #'string-equal))
         (param-forms
           (loop for param in query-params
                 for name = (parameter-definition-name param)
                 for var = (intern (symbol-name (parameter-definition-cl-name param))
                                   *generated-function-package*)
                 collect `(when ,var
                            (cons ,name (princ-to-string ,var)))))
         ;; Only add page form if paginated and page isn't already a query param
         (page-form (when (and paginated (not has-page-in-query))
                      `(when page
                         (cons "page" (princ-to-string page))))))
    (when (or param-forms page-form)
      `(remove nil
               (list ,@param-forms
                     ,@(when page-form (list page-form)))))))

(defun generate-http-request-call (method path-var query-var body-param requires-auth)
  "Generate the HTTP-REQUEST function call form.

METHOD: HTTP method keyword (:get, :post, etc.)
PATH-VAR: Symbol bound to the request path
QUERY-VAR: Symbol bound to query parameters alist, or NIL if no query params
BODY-PARAM: Body parameter definition (for POST/PUT)
REQUIRES-AUTH: Whether the endpoint requires authentication

Returns an HTTP-REQUEST call form."
  (let ((args `(client ,path-var :method ,method)))
    ;; Query parameters (only include if there are any)
    (when query-var
      (setf args (append args `(:query-params ,query-var))))
    ;; Body content (for POST/PUT/DELETE with body)
    (when body-param
      (let ((body-var (intern (symbol-name (parameter-definition-cl-name body-param))
                              *generated-function-package*)))
        (setf args (append args `(:content
                                  (when ,body-var
                                    (com.inuoe.jzon:stringify ,body-var)))))))
    ;; Authentication
    (when requires-auth
      (setf args (append args '(:bearer-token token))))
    `(http-request ,@args)))

;;; ---------------------------------------------------------------------------
;;; Response handling
;;; ---------------------------------------------------------------------------

(defun generate-response-handling (endpoint)
  "Generate the response parsing and return form.

For simple endpoints: extracts the response body.
For paginated endpoints: returns values of body and page info.

ENDPOINT: An endpoint-definition struct

Returns a form that processes the response."
  (if (endpoint-definition-paginated-p endpoint)
      ;; Paginated: return body + page info
      `(values (esi-response-body response)
               (let ((headers (esi-response-headers response)))
                 (when headers
                   (multiple-value-bind (etag expires pages)
                       (extract-esi-metadata headers)
                     (declare (ignore etag expires))
                     pages)))
               response)
      ;; Simple: just the body and the full response
      `(values (esi-response-body response) response)))

;;; ---------------------------------------------------------------------------
;;; Docstring generation
;;; ---------------------------------------------------------------------------

(defun generate-docstring (endpoint)
  "Generate a comprehensive docstring for an endpoint function.

The docstring includes:
  - Summary line from the endpoint description
  - HTTP method and path
  - Authentication requirements and required scopes
  - Parameter documentation with types and descriptions
  - Response type information
  - Cache duration information
  - Deprecation notice if applicable
  - Usage example

ENDPOINT: An endpoint-definition struct

Returns a string."
  (with-output-to-string (s)
    ;; Summary
    (let ((summary (or (endpoint-definition-summary endpoint)
                       (endpoint-definition-description endpoint)
                       "No description available.")))
      (write-string summary s))
    (terpri s)
    ;; Separator
    (terpri s)
    ;; Method and path
    (format s "ESI Endpoint: ~A ~A~%"
            (endpoint-definition-method endpoint)
            (endpoint-definition-path endpoint))
    ;; Operation ID
    (format s "Operation ID: ~A~%"
            (endpoint-definition-operation-id endpoint))
    ;; Category
    (when (endpoint-definition-category endpoint)
      (format s "Category: ~A~%" (endpoint-definition-category endpoint)))
    ;; Authentication
    (if (endpoint-definition-requires-auth-p endpoint)
        (progn
          (format s "Authentication: Required~%")
          (when (endpoint-definition-required-scopes endpoint)
            (format s "Required Scopes: ~{~A~^, ~}~%"
                    (endpoint-definition-required-scopes endpoint))))
        (format s "Authentication: Not required (public endpoint)~%"))
    ;; Parameters section
    (let ((path-params (endpoint-definition-path-parameters endpoint))
          (query-params (endpoint-definition-query-parameters endpoint))
          (body-param (endpoint-definition-body-parameter endpoint)))
      (when (or path-params query-params body-param)
        (terpri s)
        (format s "Parameters:~%")
        ;; Path parameters (required positional args)
        (dolist (param path-params)
          (format-parameter-doc param s :positional))
        ;; Query parameters (keyword args)
        (dolist (param query-params)
          (format-parameter-doc param s :keyword))
        ;; Body parameter
        (when body-param
          (format-parameter-doc body-param s :body))))
    ;; Pagination
    (when (endpoint-definition-paginated-p endpoint)
      (terpri s)
      (format s "Pagination: This endpoint supports pagination.~%")
      (format s "  Use :PAGE to request a specific page (1-indexed).~%")
      (format s "  Returns: (VALUES data total-pages response)~%"))
    ;; Response type
    (when-let ((schema (endpoint-definition-response-schema endpoint)))
      (terpri s)
      (format s "Response Type: ~A" (schema-definition-type schema))
      (when (eq (schema-definition-type schema) :array)
        (when-let ((items (schema-definition-items-schema schema)))
          (format s " of ~A" (schema-definition-type items))))
      (terpri s)
      (when (endpoint-definition-response-description endpoint)
        (format s "Response: ~A~%" (endpoint-definition-response-description endpoint))))
    ;; Caching
    (when (endpoint-definition-cache-duration endpoint)
      (terpri s)
      (format s "Cache Duration: ~D seconds~%"
              (endpoint-definition-cache-duration endpoint)))
    ;; Deprecation
    (when (endpoint-definition-deprecated-p endpoint)
      (terpri s)
      (format s "WARNING: This endpoint is DEPRECATED.~%")
      (when (endpoint-definition-alternate-routes endpoint)
        (format s "Alternate routes: ~{~A~^, ~}~%"
                (endpoint-definition-alternate-routes endpoint))))
    ;; Usage example
    (terpri s)
    (format s "Example:~%")
    (format s "  ~A" (generate-usage-example endpoint))))

(defun format-parameter-doc (param stream style)
  "Format a single parameter's documentation.

PARAM: A parameter-definition struct
STREAM: Output stream
STYLE: One of :POSITIONAL, :KEYWORD, :BODY"
  (let ((name (parameter-definition-name param))
        (cl-name (parameter-definition-cl-name param))
        (description (parameter-definition-description param))
        (schema (parameter-definition-schema param))
        (required-p (parameter-definition-required-p param))
        (default-val (parameter-definition-default-value param))
        (enum-vals (parameter-definition-enum-values param)))
    (format stream "  ~A" 
            (ecase style
              (:positional (string-upcase (symbol-name cl-name)))
              (:keyword (format nil ":~A" (symbol-name cl-name)))
              (:body "BODY")))
    ;; Type info
    (when schema
      (format stream " (~A" (or (schema-definition-type schema) "any"))
      (when (schema-definition-format schema)
        (format stream "/~A" (schema-definition-format schema)))
      (format stream ")"))
    ;; Required/optional
    (format stream " - ~:[Optional~;Required~]" required-p)
    ;; Description
    (when description
      (format stream ". ~A" (string-trim '(#\Space #\Newline #\. ) description)))
    ;; Default value
    (when default-val
      (format stream " [default: ~S]" default-val))
    ;; Enum values
    (when enum-vals
      (format stream " [values: ~{~S~^, ~}]" enum-vals))
    (terpri stream)))

(defun generate-usage-example (endpoint)
  "Generate a usage example for an endpoint function.

ENDPOINT: An endpoint-definition struct

Returns a string showing a typical function call."
  (let* ((fn-name (endpoint-definition-function-name endpoint))
         (path-params (endpoint-definition-path-parameters endpoint))
         (parts (list (format nil "(~A client" fn-name))))
    ;; Add path param examples
    (dolist (param path-params)
      (push (generate-example-value param) parts))
    ;; Close paren
    (let ((result (format nil "~{~A~^ ~})" (nreverse parts))))
      result)))

(defun generate-example-value (param)
  "Generate an example value for a parameter.

PARAM: A parameter-definition struct

Returns a string representing an example value."
  (let ((schema (parameter-definition-schema param))
        (name (parameter-definition-name param)))
    (cond
      ;; Known EVE ID patterns
      ((search "character_id" name) "95465499")
      ((search "corporation_id" name) "109299958")
      ((search "alliance_id" name) "434243723")
      ((search "region_id" name) "10000002")
      ((search "system_id" name) "30000142")
      ((search "station_id" name) "60003760")
      ((search "type_id" name) "34")
      ((search "war_id" name) "1941")
      ((search "contract_id" name) "1234567")
      ((search "killmail_id" name) "12345678")
      ;; Type-based defaults
      ((and schema (eq (schema-definition-type schema) :integer)) "12345")
      ((and schema (eq (schema-definition-type schema) :string)) "\"example\"")
      ((and schema (eq (schema-definition-type schema) :boolean)) "t")
      (t "value"))))

;;; ---------------------------------------------------------------------------
;;; Function naming conventions
;;; ---------------------------------------------------------------------------

(defun endpoint-to-symbol (endpoint &optional (package *generated-function-package*))
  "Convert an endpoint-definition to a symbol suitable for a function name.

ENDPOINT: An endpoint-definition struct
PACKAGE: Target package for the symbol (default: *generated-function-package*)

Returns a symbol."
  (intern (string-upcase (endpoint-definition-function-name endpoint))
          package))

(defun category-package-name (category)
  "Generate a package name for an ESI endpoint category.

CATEGORY: Category string (e.g., \"characters\", \"markets\")

Returns a package name string.

Example:
  (category-package-name \"characters\") => \"EVE-GATE.API.CHARACTERS\""
  (format nil "EVE-GATE.API.~A" (string-upcase category)))

;;; ---------------------------------------------------------------------------
;;; Batch generation
;;; ---------------------------------------------------------------------------

(defun generate-category-forms (endpoints category)
  "Generate all function forms for endpoints in a given category.

ENDPOINTS: List of endpoint-definition structs
CATEGORY: Category string to filter by

Returns a list of DEFUN forms for all endpoints in the category."
  (let ((category-endpoints
          (remove-if-not (lambda (ep)
                           (string-equal (endpoint-definition-category ep) category))
                         endpoints)))
    (mapcar #'generate-endpoint-function-form category-endpoints)))

(defun generate-all-function-forms (endpoints)
  "Generate DEFUN forms for all endpoints.

ENDPOINTS: List of endpoint-definition structs

Returns an alist of (category . list-of-forms) pairs."
  (let ((categories (remove-duplicates
                     (mapcar #'endpoint-definition-category endpoints)
                     :test #'string-equal))
        (result '()))
    (dolist (cat (sort (copy-list categories) #'string<))
      (push (cons cat (generate-category-forms endpoints cat))
            result))
    (nreverse result)))

;;; ---------------------------------------------------------------------------
;;; File generation
;;; ---------------------------------------------------------------------------

(defun generate-category-file-form (endpoints category &key
                                                          (header t)
                                                          (in-package :eve-gate.api))
  "Generate the complete file content for a category's API functions.

ENDPOINTS: List of endpoint-definition structs
CATEGORY: Category string
HEADER: Whether to include a file header comment (default: T)
IN-PACKAGE: Package designation (default: :eve-gate.api)

Returns a list of forms comprising the file contents."
  (let ((forms '())
        (category-endpoints
          (sort (remove-if-not
                 (lambda (ep)
                   (string-equal (endpoint-definition-category ep) category))
                 endpoints)
                #'string<
                :key #'endpoint-definition-operation-id)))
    ;; File header
    (when header
      (push `(comment
              ,(format nil ";;;; ~A.lisp - Generated ESI API functions for ~A endpoints~%~
                            ;;;;~%~
                            ;;;; This file is AUTO-GENERATED by the eve-gate code generation framework.~%~
                            ;;;; Do not edit manually. Changes will be overwritten on regeneration.~%~
                            ;;;;~%~
                            ;;;; Category: ~A~%~
                            ;;;; Endpoints: ~D~%~
                            ;;;; Generated: ~A"
                       category category
                       category
                       (length category-endpoints)
                       (format-generation-timestamp)))
            forms))
    ;; In-package form
    (push `(in-package ,in-package) forms)
    ;; Function definitions
    (dolist (ep category-endpoints)
      (push (generate-endpoint-function-form ep) forms))
    (nreverse forms)))

(defun format-generation-timestamp ()
  "Return a human-readable timestamp string for generation headers."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D UTC"
            year month day hour min sec)))

;;; ---------------------------------------------------------------------------
;;; Form serialization (writing Lisp forms to files)
;;; ---------------------------------------------------------------------------

(defun write-generated-form (form stream &key (pretty t))
  "Write a single generated Lisp form to STREAM.

Handles the special COMMENT form type for file header comments.

FORM: A Lisp form (list)
STREAM: Output stream
PRETTY: Whether to use pretty-printing (default: T)"
  (cond
    ;; Special comment form
    ((and (consp form) (eq (car form) 'comment))
     (write-string (cadr form) stream)
     (terpri stream))
    ;; Normal Lisp form
    (t
     (let ((*print-case* :downcase)
           (*print-pretty* pretty)
           (*print-right-margin* 100))
       (pprint form stream)
       (terpri stream)
       (terpri stream)))))

(defun write-generated-file (forms pathname &key (if-exists :supersede))
  "Write a list of generated forms to a file.

FORMS: List of Lisp forms to write
PATHNAME: Target file path
IF-EXISTS: File existence policy (default: :supersede)

Returns the pathname."
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output
                                :if-exists if-exists
                                :if-does-not-exist :create
                                :external-format :utf-8)
    (dolist (form forms)
      (write-generated-form form out)))
  (log-info "Generated file: ~A (~D forms)" pathname (length forms))
  pathname)

;;; ---------------------------------------------------------------------------
;;; Change detection for incremental regeneration
;;; ---------------------------------------------------------------------------

(defun endpoint-signature (endpoint)
  "Compute a signature string for an endpoint definition that changes when
the endpoint's code-generation-relevant metadata changes.

Used for incremental regeneration: only regenerate files whose endpoints
have changed signatures.

ENDPOINT: An endpoint-definition struct

Returns a string."
  (format nil "~A:~A:~A:~{~A~^,~}:~{~A~^,~}:~A:~A"
          (endpoint-definition-operation-id endpoint)
          (endpoint-definition-method endpoint)
          (endpoint-definition-path endpoint)
          (mapcar #'parameter-definition-name
                  (endpoint-definition-parameters endpoint))
          (or (endpoint-definition-required-scopes endpoint) '("none"))
          (endpoint-definition-paginated-p endpoint)
          (endpoint-definition-deprecated-p endpoint)))

(defun category-signature (endpoints category)
  "Compute a composite signature for all endpoints in a category.

ENDPOINTS: List of endpoint-definition structs
CATEGORY: Category string

Returns a string that changes when any endpoint in the category changes."
  (let ((cat-endpoints
          (sort (remove-if-not
                 (lambda (ep)
                   (string-equal (endpoint-definition-category ep) category))
                 endpoints)
                #'string<
                :key #'endpoint-definition-operation-id)))
    (format nil "~{~A~^|~}" (mapcar #'endpoint-signature cat-endpoints))))
