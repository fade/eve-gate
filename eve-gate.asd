;; -*-lisp-*-
;;;; eve-gate.asd

(asdf:defsystem #:eve-gate
  :description "A library to query and set data from the Eve Online game, as published
in their public API"
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "GNU Affero GPL V.3 or later"
  :serial t
  :depends-on (#:dexador
               #:com.inuoe.jzon
               #:alexandria
               #:rutils
               #:mito
               #:postmodern
               #:lparallel
               #:openapi-generator
               #:cl-remizmq
               )
  :pathname "./"
  :components ((:file "app-utils")
               (:file "eve-gate")))

