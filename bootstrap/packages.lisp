;;;; The CL package system.
;;;; This file must be loaded last during system bootstrapping.

(in-package "SYSTEM.INTERNALS")

(declaim (special *package*))

(defvar *package-list* '()
  "The package registry.")

(defstruct (package
	     (:constructor %make-package (name nicknames))
	     (:predicate packagep))
  name
  nicknames
  use-list
  used-by-list
  internal-symbols
  external-symbols)

(defun list-all-packages ()
  (remove-duplicates (mapcar #'cdr *package-list*)))

(defmacro in-package (name)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setq *package* (find-package-or-die ',name))))

(defun find-package (name)
  (if (packagep name)
      name
      (cdr (assoc (string name) *package-list* :test #'string=))))

(defun find-package-or-die (name)
  (or (find-package name)
      (error "No package named ~S." name)))

(defun use-one-package (package-to-use package)
  (when (string= (package-name package-to-use) "KEYWORD")
    (error "Cannot use the KEYWORD package."))
  (pushnew package-to-use (package-use-list package))
  (pushnew package (package-used-by-list package-to-use)))

(defun use-package (packages-to-use &optional (package *package*))
  (let ((p (find-package package)))
    (if (listp packages-to-use)
	(dolist (use-package packages-to-use)
	  (use-one-package (find-package use-package) p))
	(use-one-package (find-package packages-to-use) p)))
  t)

(defun make-package (package-name &key nicknames use)
  (when (find-package package-name)
    (error "A package named ~S already exists." package-name))
  (dolist (n nicknames)
    (when (find-package n)
      (error "A package named ~S already exists." n)))
  (let ((use-list (mapcar #'find-package use))
	(package (%make-package (simplify-string (string package-name))
				(mapcar (lambda (x) (simplify-string (string x))) nicknames))))
    ;; Use packages.
    (use-package use-list package)
    ;; Install the package in the package registry.
    (push (cons (package-name package) package) *package-list*)
    (dolist (s (package-nicknames package))
      (push (cons s package) *package-list*))
    package))

(defun find-symbol (string &optional (package *package*))
  (let ((p (find-package-or-die package)))
    (let ((sym (member string (package-internal-symbols p) :key #'symbol-name :test #'string=)))
      (when sym
	(return-from find-symbol (values (car sym) :internal))))
    (let ((sym (member string (package-external-symbols p) :key #'symbol-name :test #'string=)))
      (when sym
	(return-from find-symbol (values (car sym) :external))))
    (dolist (pak (package-use-list p)
	     (values nil nil))
      (multiple-value-bind (symbol status)
	  (find-symbol string pak)
	(when (or (eq status :external)
		  (eq status :inherited))
	  (return (values symbol :inherited)))))))

(defun import-one-symbol (symbol package)
  ;; Check for a conflicting symbol.
  (multiple-value-bind (existing-symbol existing-mode)
      (find-symbol (symbol-name symbol) package)
    (when (and existing-mode
	       (not (eq existing-symbol symbol)))
      (ecase existing-mode
	(:inherited
	 ;; TODO: Restarts shadow-symbol and don't import.
	 (error "Newly imported symbol ~S conflicts with inherited symbol ~S." symbol existing-symbol))
	((:internal :external)
	 ;; TODO: Restarts unintern-old-symbol and don't import.
	 (error "Newly imported symbol ~S conflicts with present symbol ~S." symbol existing-symbol))))
    (unless (find symbol (package-external-symbols package))
      (pushnew symbol (package-internal-symbols package)))
    (unless (symbol-package symbol)
      (setf (symbol-package symbol) package))))

(defun import (symbols &optional (package *package*))
  (let ((p (find-package-or-die package)))
    (if (listp symbols)
	(dolist (s symbols)
	  (import-one-symbol s p))
	(import-one-symbol symbols p)))
  t)

(defun export-one-symbol (symbol package)
  (dolist (q (package-used-by-list package))
    (multiple-value-bind (other-symbol status)
	(find-symbol (symbol-name symbol) q)
      (when (and (not (eq symbol other-symbol))
		 status)
	;; TODO: Restart replace-symbol.
	(error "Newly exported symbol ~S conflicts with symbol ~S in package ~S." symbol other-symbol q))))
  (import-one-symbol symbol package)
  ;; Remove from the internal-symbols list.
  (setf (package-internal-symbols package) (delete symbol (package-internal-symbols package)))
  ;; And add to the external-symbols list.
  (pushnew symbol (package-external-symbols package)))

(defun export (symbols &optional (package *package*))
  (let ((p (find-package-or-die package)))
    (if (listp symbols)
	(dolist (s symbols)
	  (export-one-symbol s p))
	(export-one-symbol symbols p)))
  t)

;;; Create the core packages when the file is first loaded.
;;; *PACKAGE* is set to system.internals initially.
(unless *package-list*
  (make-package "KEYWORD")
  (make-package "COMMON-LISP" :nicknames '("CL"))
  (make-package "SYSTEM" :nicknames '("SYS") :use '("CL"))
  (make-package "SYSTEM.INTERNALS" :nicknames '("SYS.INT") :use '("CL" "SYS"))
  (make-package "COMMON-LISP-USER" :nicknames '("CL-USER") :use '("CL"))
  (setf *package* (find-package-or-die "SYSTEM.INTERNALS")))

;; Function FIND-SYMBOL
;; Function FIND-ALL-SYMBOLS
;; Function RENAME-PACKAGE
;; Function SHADOW
;; Function SHADOWING-IMPORT
;; Function DELETE-PACKAGE
;; Macro WITH-PACKAGE-ITERATOR
;; Function UNEXPORT
;; Function UNINTERN
;; Function UNUSE-PACKAGE
;; Macro DO-SYMBOLS, DO-EXTERNAL-SYMBOLS, DO-ALL-SYMBOLS
;; Function PACKAGE-SHADOWING-SYMBOLS
;; Condition Type PACKAGE-ERROR
;; Function PACKAGE-ERROR-PACKAGE

;;; The definition of intern and the switch over to the full package system
;;; must be done together.
(progn
  (defun intern (name &optional (package *package*))
    (let ((p (find-package-or-die package)))
      (multiple-value-bind (symbol status)
	  (find-symbol name p)
	(when status
	  (return-from intern (values symbol status))))
      (let ((symbol (make-symbol name)))
	(import (list symbol) p)
	(when (string= (package-name p) "KEYWORD")
	  ;; TODO: Constantness.
	  (setf (symbol-value symbol) symbol)
	  (export (list symbol) p))
	(values symbol nil))))
  (jettison-bootstrap-package-system)
  (defun jettison-bootstrap-package-system ()))

(defun delete-package (package)
  (let ((p (find-package-or-die package)))
    (when (package-used-by-list p)
      (error "Package ~S is in use." package))
    ;; Remove the package from the use list.
    (dolist (other (package-use-list p))
      (setf (package-used-by-list other) (remove p (package-used-by-list other))))
    ;; Remove all symbols.
    (dolist (symbol (package-internal-symbols p))
      (when (eq (symbol-package symbol) package)
	(setf (symbol-package symbol) nil)))
    (dolist (symbol (package-external-symbols p))
      (when (eq (symbol-package symbol) package)
	(setf (symbol-package symbol) nil)))
    (setf (package-name p) nil)
    (setf *package-list* (remove p *package-list* :key #'cdr))
    t))

(defun keywordp (object)
  (and (symbolp object)
       (eq (symbol-package object) (find-package "KEYWORD"))))

;;; TODO: shadowing symbols.
(defun %defpackage (name nicknames documentation use-list import-list export-list intern-list)
  (let ((p (or (find-package name)
	       (make-package name :nicknames nicknames))))
    (use-package use-list p)
    (import import-list p)
    (dolist (s intern-list)
      (intern s p))
    (dolist (s export-list)
      (export-one-symbol (intern (string s) p) p))
    p))

(defmacro defpackage (defined-package-name &rest options)
  (let ((nicknames '())
	(documentation nil)
	(use-list '())
	(import-list '())
	(export-list '())
	(intern-list '()))
    (dolist (o options)
      (ecase (first o)
	(:nicknames
	 (dolist (n (rest o))
	   (pushnew (string n) nicknames)))
	(:documentation
	 (when documentation
	   (error "Multiple documentation options in DEFPACKAGE form."))
	 (unless (or (eql 2 (length o))
		     (not (stringp (second o))))
	   (error "Invalid documentation option in DEFPACKAGE form."))
	 (setf documentation (second o)))
	(:use
	 (dolist (u (rest o))
	   (if (packagep u)
	       (pushnew u use-list)
	       (pushnew (string u) use-list))))
	(:import-from
	 (let ((package (find-package-or-die (second o))))
	   (dolist (name (cddr o))
	     (multiple-value-bind (symbol status)
		 (find-symbol (string name) package)
	       (unless status
		 (error "No such symbol ~S in package ~S." (string name) package))
	       (pushnew symbol import-list)))))
	(:export
	 (dolist (name (cdr o))
	   (pushnew name export-list)))
	(:intern
	 (dolist (name (cdr o))
	   (pushnew name intern-list)))
	(:size)))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (%defpackage ,(string defined-package-name)
		    ',nicknames
		    ',documentation
		    ',use-list
		    ',import-list
		    ',export-list
		    ',intern-list))))