pj = try require 'prettyjson'
render = (obj) -> pj?.render obj
{debug} = require './helpers'
reporter = require './reporter'
{clone, rewrite} = require './type-helpers'
reporter = require './reporter'

typeErrorText = (left, right) ->
  "TypeError: #{JSON.stringify left} expect to #{JSON.stringify right}"

class Type
  constructor: ->

# ObjectType :: T -> Object
class ObjectType extends Type
  # :: String -> ()
  constructor:(@dataType) ->

# ArrayType :: {array :: T} = array: T
class ArrayType extends Type
  constructor:(dataType) ->
    @array = dataType

# possibilities :: Type[] = []
class Possibilites extends Array
  constructor: (arr = []) ->
    @push i for i in arr

checkAcceptableObject = (left, right, scope) =>
  # TODO: fix
  if left?._base_? and left._templates_? then left = left._base_

  # possibilites :: Type[]
  if right?.possibilities?
    results = (checkAcceptableObject left, r, scope for r in right.possibilities)
    return (if results.every((i)-> not i) then false else results.filter((i)-> i).join('\n'))

  # Any
  if left is 'Any'
    return false

  if left?.arguments
    return if left is undefined or left is 'Any'
    left.arguments ?= []
    results = (checkAcceptableObject(l_arg, right.arguments[i], scope) for l_arg, i in left.arguments)
    return (if results.every((i)-> not i) then false else results.filter((i)-> i).join('\n'))

    # check return dataType
    # TODO: Now I will not infer function return dataType
    if right.returnType isnt 'Any'
      return checkAcceptableObject(left.returnType, right.returnType, scope)
    return false

  if left?.array?
    if right.array instanceof Array
      results = (checkAcceptableObject left.array, r, scope for r in right.array)
      return (if results.every((i)-> not i) then false else results.filter((i)-> i).join('\n'))
    else
      return checkAcceptableObject left.array, right.array, scope

  else if right?.array?
    if left is 'Array' or left is 'Any' or left is undefined
      return false
    else
      return typeErrorText left, right

  else if ((typeof left) is 'string') and ((typeof right) is 'string')
    cur = scope.getTypeInScope(left)
    extended_list = [left]
    while cur._extends_
      extended_list.push cur._extends_
      cur = scope.getTypeInScope cur._extends_
    # TODO: handle object
    # now only allow primitive
    if (left is 'Any') or (right is 'Any') or right in extended_list
      return false
    else
      return typeErrorText left, right

  else if ((typeof left) is 'object') and ((typeof right) is 'object')
    results =
      for key, lval of left
        if right[key] is undefined and lval? and not (key in ['returnType', 'type', 'possibilities']) # TODO avoid system values
          "'#{key}' is not defined on right"
        else
          checkAcceptableObject(lval, right[key], scope)
    return (if results.every((i)-> not i) then false else results.filter((i)-> i).join('\n'))
  else if (left is undefined) or (right is undefined)
    return false
  else
    return typeErrorText left, right

# Initialize primitive types
# Number, Boolean, Object, Array, Any
initializeGlobalTypes = (node) ->
  # Primitive
  node.addTypeObject 'String', new TypeSymbol {dataType: 'String'}
  node.addTypeObject 'Number', new TypeSymbol {dataType: 'Number', _extends_: 'Float'}
  node.addTypeObject 'Int', new TypeSymbol {dataType: 'Int'}
  node.addTypeObject 'Float', new TypeSymbol {dataType: 'Float', _extends_: 'Int'}
  node.addTypeObject 'Boolean', new TypeSymbol {dataType: 'Boolean'}
  node.addTypeObject 'Object', new TypeSymbol {dataType: 'Object'}
  node.addTypeObject 'Array', new TypeSymbol {dataType: 'Array'}
  node.addTypeObject 'Undefined', new TypeSymbol {dataType: 'Undefined'}
  node.addTypeObject 'Any', new TypeSymbol {dataType: 'Any'}

# Known vars in scope
class VarSymbol
  # dataType :: String
  # explicit :: Boolean
  constructor: ({@dataType, @explicit}) ->
    @explicit ?= false

# Known types in scope
class TypeSymbol
  # dataType :: String or Object
  # instanceof :: (Any) -> Boolean
  constructor: ({@dataType, @instanceof, @_templates_, @_extends_}) ->

# Var and dataType scope as node
class Scope
  # constructor :: (Scope) -> Scope
  constructor: (@parent = null) ->
    @parent?.nodes.push this

    @name = ''
    @nodes  = [] #=> Scope[]

    # Scope vars
    @_vars  = {} #=> String -> Type

    # Scope dataTypes
    @_types = {} #=> String -> Type

    # This scope
    @_this  = {}

    # Module scope
    @_modules  = {}

    @_returnables = [] #=> Type[]

  addReturnable: (symbol, dataType) ->
    @_returnables.push dataType

  getReturnables: -> @_returnables

  getRoot: ->
    return @ unless @parent
    root = @parent
    while true
      if root.parent
        root = root.parent
      else break
    root

  # addType :: Any * Object * Object -> Type
  addModule: (name) ->
    scope = new Scope this
    scope.name = name
    return @_modules[name] = scope

  getModule: (name) -> @_modules[name]

  getModuleInScope: (name) ->
    @getModule(name) or @parent?.getModuleInScope(name) or undefined

  # addType :: Any * Object * Object -> Type
  addType: (symbol, dataType, _templates_) ->
    if symbol?.left?
      # get namescopes
      ns = []
      name = symbol.right
      cur = symbol.left
      while true
        if (typeof cur) is 'string'
          ns.unshift cur
          break
        else
          ns.unshift cur.right
          cur = cur.left

      # find or initialize module
      cur = @
      for moduleName in ns
        mod = cur.getModuleInScope(moduleName)
        unless mod
          mod = cur.addModule(moduleName)
        cur = mod
      cur.addType name, dataType, _templates_
    else
      @_types[symbol] = new TypeSymbol {dataType, _templates_}

  addTypeObject: (symbol, type_object) ->
    @_types[symbol] = type_object

  getType: (symbol) ->
    if symbol?.left?
      # get namescopes
      ns = []
      name = symbol.right
      cur = symbol.left
      while true
        if (typeof cur) is 'string'
          ns.unshift cur
          break
        else
          ns.unshift cur.right
          cur = cur.left

      # find or initialize module
      cur = @
      for moduleName in ns
        mod = cur.getModuleInScope(moduleName)
        unless mod
          return null
        cur = mod
      cur.getType name
    else
      @_types[symbol]

  getTypeInScope: (symbol) ->
    @getType(symbol) or @parent?.getTypeInScope(symbol) or undefined

  addThis: (symbol, dataType) ->
    # TODO: Refactor with addVar
    if dataType?._base_?
      T = @getType(dataType._base_)
      return undefined unless T
      obj = clone T.dataType
      if T._templates_
        # TODO: length match
        rewrite_to = dataType._templates_
        replacer = {}
        for t, n in T._templates_
          replacer[t] = rewrite_to[n]
        rewrite obj, replacer

      @_this[symbol] = new VarSymbol {dataType:obj}
    else
      @_this[symbol] = new VarSymbol {dataType}

  getThis: (symbol) ->
    @_this[symbol]

  addVar: (symbol, dataType, explicit) ->
    # TODO: Refactor
    if dataType?._base_?
      T = @getType(dataType._base_)
      return undefined unless T
      obj = clone T.dataType
      if T._templates_
        # TODO: length match
        rewrite_to = dataType._templates_
        replacer = {}
        for t, n in T._templates_
          replacer[t] = rewrite_to[n]
        rewrite obj, replacer

      @_vars[symbol] = new VarSymbol {dataType:obj, explicit}
    else
      @_vars[symbol] = new VarSymbol {dataType, explicit}

  getVar: (symbol) ->
    @_vars[symbol]

  getVarInScope: (symbol) ->
    @getVar(symbol) or @parent?.getVarInScope(symbol) or undefined

  isImplicitVarInScope: (symbol) ->
    @isImplicitVar(symbol) or @parent?.isImplicitVarInScope(symbol) or undefined

  # Extend symbol to dataType object
  # ex. {name : String, p : Point} => {name : String, p : { x: Number, y: Number}}
  extendTypeLiteral: (node) =>
    if (typeof node) is 'string' or node?.nodeType is 'MemberAccess'
      Type = @getTypeInScope(node)
      dataType = Type?.dataType
      switch typeof dataType
        when 'object'
          return @extendTypeLiteral(dataType)
        when 'string'
          return dataType

    else if (typeof node) is 'object'
      # array
      if node instanceof Array
        return (@extendTypeLiteral(i) for i in node)
      # object
      else
        ret = {}
        for key, val of node
          ret[key] = @extendTypeLiteral(val)
        return ret

  # check object literal with extended object
  checkAcceptableObject: (left, right) ->
    l = @extendTypeLiteral(left)
    r = @extendTypeLiteral(right)
    return checkAcceptableObject(l, r, @)

class ClassScope extends Scope
class FunctionScope extends Scope

module.exports = {
  checkAcceptableObject,
  initializeGlobalTypes,
  VarSymbol, TypeSymbol, Scope, ClassScope, FunctionScope
  ArrayType, ObjectType, Type, Possibilites
}