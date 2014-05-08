library angular.core_dom.node_property_binder;

import 'package:angular/change_detection/watch_group.dart' show Watch;
import 'package:angular/core/parser/parser.dart' show Parser, Setter, Getter;
import 'package:angular/core/parser/syntax.dart' show Expression;
import 'package:angular/core/module_internal.dart' show
    Scope, ScopeEvent, FormatterMap, ExceptionHandler, ReactionFn;
import 'package:angular/core/annotation.dart' show Directive, AttachAware, DetachAware;

import 'package:di/di.dart';
import 'dart:html' show Node, Element;

bool same(a, b) =>
    identical(a, b) ||
    (a is String && b is String && a == b) ||
    (a is num && a.isNaN && b is num && b.isNaN);

Map<Type, Map<String, bool>> _understandsMap = {};
bool _understandsGetter(Object obj, String property, Getter getter) {
  var type = obj.runtimeType;
  var propertyMap = _understandsMap[type];
  if (propertyMap == null) _understandsMap[type] = propertyMap = {};
  var understands = propertyMap[property];
  if (understands == null) {
    try {
      getter(obj);
      understands = true;
    } on NoSuchMethodError catch (e) {
      understands = false;
    }
    propertyMap[property] = understands;
  }
  return understands;
}

class Case {
  static final _DASH = new RegExp(r'-+(.)');
  static final _CAMEL = new RegExp(r'([A-Z]+)');
  final _toDash = {};
  final _toCamel = {};

  Case() {
    preset('readonly', 'readOnly');
  }

  void preset(String dash, String camel) {
    _toCamel[dash] = camel;
    _toDash[camel] = dash;
  }

  /// Convert `node-property` attribute name to `nodeProperty` property name.
  String camel(String dash) => _toCamel.putIfAbsent(dash, () {
    return dash.replaceAllMapped(_DASH, (Match m) => m.group(1).toUpperCase());
  });

  String dash(String camel) => _toDash.putIfAbsent(camel, () {
    var dash = camel.replaceAllMapped(_CAMEL, (Match m) => '-' + m.group(1).toLowerCase());
    if (dash.startsWith('-')) dash = dash.substring(1);
    return dash;
  });

}

class NodeBinderBuilder {
  static final Case _case = new Case();
  static final RegExp _CHILD = new RegExp(r'^(\d+)-(text)$'); // support text only
  final Parser parser;
  final ExceptionHandler exceptionHandler;
  final _dashCaseMap = {
  };
  final _camelCaseMap = {
    'readonly': 'readOnly'
  };

  NodeBinderBuilder(this.parser, this.exceptionHandler);

  /**
   * Compile a list of binders from a template prototype.
   *
   * - [templateNode]: template node used to determine what properties the node has.
   * - [events]: a list of DOM events which are associated with changes in the DOM properties.
   * - [bindings]: property name to expressions representing bindings between node and model
   * - [directives]: a map of directive [Type]s to [Directive] annotation representing additional
   *   bindings between the directive and node.
   */
  NodeBinder build(
      Element templateNode,
      List<String> events,
      Map<String, String> bindings,
      Map<Type, Directive> directives)
  {
    var nodePropertyBinders = <String, NodePropertyBinder>{};
    var nakedNodePropertyBinder = new NodePropertyBinder();
    var childNodePropertyBinders = [];
    var directiveTypes = <Type>[];
    var childNodes;
    bindings.forEach((String propertyName, String propertyBindExp) {
      var match = _CHILD.firstMatch(propertyName);
      if (match != null) {
        var childIndex = int.parse(match.group(1));
        propertyName = _case.camel(match.group(2));
        if (childNodes == null) childNodes = templateNode.childNodes;
        if (childIndex < childNodes.length) {
          childNodePropertyBinders.length = childIndex + 1; // make sure that we have right length
          childNodePropertyBinders[childIndex] =
              _createNodePropertyBinder(childNodes[childIndex], propertyName, propertyBindExp);
        }
      } else {
        propertyName = _case.camel(propertyName);
        nodePropertyBinders[propertyName] =
            _createNodePropertyBinder(templateNode, propertyName, propertyBindExp);
      }
    });
    directives.forEach((Type directiveType, Directive annotation) {
      var directiveIndex = directiveTypes.length;
      directiveTypes.add(directiveType);
      var directivePropertyBinders = <String, DirectivePropertyBinder>{};
      _forEach(annotation.bind, (String nodeProp, String directiveExp) {
        var nodePropertyBinder = nodePropertyBinders.putIfAbsent(nodeProp, () {
          return _createNodePropertyBinder(templateNode, nodeProp);
        });
        var cDirExp = parser(directiveExp);
        var directivePropertyBinder = new DirectivePropertyBinder(
            directiveIndex, directiveExp, getter(cDirExp), setter(cDirExp));
        directivePropertyBinders[directiveExp] = directivePropertyBinder;
        nodePropertyBinder.directivePropertyBinders.add(directivePropertyBinder);
      });
      _forEach(annotation.observe, (String watchExp, String reactionFnExp) {
        var directivePropBinder = directivePropertyBinders.putIfAbsent(watchExp, () {
          // This means that this watcher does not have corresponding node property binding
          var nakedDirectivePropBinder = new DirectivePropertyBinder(directiveIndex, watchExp);
          nakedNodePropertyBinder.directivePropertyBinders.add(nakedDirectivePropBinder);
          return nakedDirectivePropBinder;
        });
        var cReactionFnExp = parser(reactionFnExp);
        directivePropBinder.reactionFnGetter = getter(cReactionFnExp);
      });
    });
    if (nakedNodePropertyBinder.directivePropertyBinders.isNotEmpty) {
      nodePropertyBinders[''] = nakedNodePropertyBinder;
    }
    return new NodeBinder(events, nodePropertyBinders.values.toList(),
                          childNodePropertyBinders, directiveTypes);
  }

  /// Extract getter from [Expression] and wrap it in try-catch block.
  Getter getter(Expression expression) {
    if (expression == null) return null;
    var nakedGetter = expression.eval;
    return (obj) {
      try {
        return nakedGetter(obj);
      } catch (e, s) {
        exceptionHandler(e, s);
      }
    };
  }

  /// Extract setter from [Expression] and wrap it in try-catch block.
  Setter setter(Expression expression) {
    if (expression == null || !expression.isAssignable) return null;
    var nakedSetter = expression.assign;
    return (obj, value) {
      try {
        return nakedSetter(obj, value);
      } catch (e, s) {
        exceptionHandler(e, s);
      }
    };
  }

  void _forEach(collection, forEachFn) {
    if (collection != null) {
      collection.forEach(forEachFn);
    }
  }

  NodePropertyBinder _createNodePropertyBinder(
      Node templateElement,
      String propertyName,
      [String propertyBindExp])
  {
    var propertyExp = parser(propertyName);
    var nodePropertyGetter;
    var nodePropertySetter;
    if (_understandsGetter(templateElement, propertyName, propertyExp.eval)) {
      nodePropertyGetter = getter(propertyExp);
      nodePropertySetter = setter(propertyExp);
    } else if (templateElement is Element) {
      var emulatedValue = templateElement.attributes[_case.dash(propertyName)];
      nodePropertyGetter = (_) => emulatedValue;
      nodePropertySetter = (_, value) => emulatedValue = value;
    }
    return new NodePropertyBinder(
        propertyName, nodePropertyGetter, nodePropertySetter, propertyBindExp,
        propertyBindExp == null ? null : setter(parser(propertyBindExp)));
  }

}

class NodeBinder {
  final List<String> events;
  final List<NodePropertyBinder> nodePropertyBinders;
  final List<NodePropertyBinder> childNodePropertyBinders;
  final List<Type> directiveTypes;

  NodeBinder(
      this.events,
      this.nodePropertyBinders,
      this.childNodePropertyBinders,
      this.directiveTypes);

  NodeBindings bind(Scope scope, FormatterMap formatters, Node node, Injector injector) {
    var directives = [];
    for(Type type in directiveTypes) {
      var directive = injector.get(type);
      directives.add(directive);
      if (directive is AttachAware) scope.rootScope.runAsync(directive.attach, stable: true);
      if (directive is DetachAware) scope.on(ScopeEvent.DESTROY).listen((_) => directive.detach());
    }
    var nodePropertyBindings = [];
    for(NodePropertyBinder binder in nodePropertyBinders) {
      nodePropertyBindings.add(binder.bind(scope, formatters, node, directives));
    }
    for(var i = 0, childNodes = node.childNodes; i < childNodePropertyBinders.length; i++) {
      var binder = childNodePropertyBinders[i];
      if (binder != null) {
        binder.bind(scope, formatters, childNodes[i], null);
      }
    }
    var nodeBindings = new NodeBindings(nodePropertyBindings);
    // TODO(misko): use EventHandler for this;
    events.forEach((e) => node.addEventListener(e, (e) => nodeBindings.check(true)));
    return nodeBindings;
  }
}

/**
 * Represents a facade to all of the individual bindings in the Node and Directive instance.
 */
class NodeBindings {
  final List<NodePropertyBinding> nodePropertyBindings;

  NodeBindings(this.nodePropertyBindings);

  /// Dirty check the Node for changes in properties.
  check(bool fromEvent) {
    for(NodePropertyBinding binding in nodePropertyBindings) {
      binding.check(fromEvent);
    }
  }
}

/**
 * Represents a prototype of a node binding. (A way to build binding).
 */
class NodePropertyBinder {
  final String property;
  final String bindExp;
  final Setter bindExpSetter;
  final Getter getter;
  final Setter setter;
  final List<DirectivePropertyBinder> directivePropertyBinders = <DirectivePropertyBinder>[];

  NodePropertyBinder([this.property, this.getter, this.setter, this.bindExp, this.bindExpSetter]);

  /// Construct an instance node binding from the prototype.
  NodePropertyBinding bind(Scope scope, FormatterMap formatters, Node node, List directives) {
    var canChangeModel = directivePropertyBinders.isNotEmpty;
    var binding = new NodePropertyBinding(
        scope, formatters, node, property, getter, setter, bindExp, bindExpSetter, canChangeModel);
    for(DirectivePropertyBinder directivePropertyBinder in directivePropertyBinders) {
      var directive = directives[directivePropertyBinder.index];
      binding.directiveBindings.add(directivePropertyBinder.bind(binding, scope, directive));
    }
    binding.check(false);
    return binding;
  }
}

/**
 * Represents a prototype of a directive binding. (A way to build binding).
 */
class DirectivePropertyBinder {
  /// Directive index in the list of directives for fast lookup.
  final int index;
  final Getter getter;
  final Setter setter;
  final String watchExp;
  Getter reactionFnGetter;

  DirectivePropertyBinder(this.index, this.watchExp, [this.getter, this.setter]);

  /// Construct an instance directive binding from the prototype.
  DirectivePropertyBinding bind(NodePropertyBinding nodeBinding, Scope scope, Object directive) {
    return new DirectivePropertyBinding(
        scope, nodeBinding, directive, getter, setter, watchExp,
        reactionFnGetter == null ? null : reactionFnGetter(directive));
  }
}

/**
 * Represents a binding between the Node instance and bind-* expressions.
 */
class NodePropertyBinding {
  final Scope scope;
  final Node node;
  final String property;
  final Getter getter;
  final Setter setter;
  final Setter bindSetter;
  final List<DirectivePropertyBinding> directiveBindings = <DirectivePropertyBinding>[];
  final bool wrapInDomWrite;
  Watch _watch;
  var _lastValue;

  NodePropertyBinding(Scope this.scope,
                      FormatterMap formatters,
                      this.node,
                      this.property,
                      this.getter,
                      this.setter,
                      String bindExp,
                      this.bindSetter,
                      bool canChangeModel)
    : wrapInDomWrite = canChangeModel
  {
    if (bindExp != null && bindExp.isNotEmpty) {
      _watch = scope.watch(bindExp, (v, _) => setValue(v),
          formatters: formatters, canChangeModel: canChangeModel);
    }
  }

  /// Manually check to see if the Node instance property has changed. Usually invoked as a result
  /// of DOM event.
  check(bool doToEvent) {
    if (!doToEvent && _watch != null) return;
    setValue(getter(node));
  }

  /// Notify binding of change, (either from the [check] method or from [DirectivePropertyBinding]).
  setValue(value) {
    if (same(value, _lastValue)) return;
    _lastValue = value;
    if (setter != null) {
      if (wrapInDomWrite) {
        scope.rootScope.domWrite(() => setter(node, value));
      } else {
        setter(node, value);
      }
    }
    if(bindSetter != null) bindSetter(scope.context, value);
    for(DirectivePropertyBinding directiveBinding in directiveBindings) {
      directiveBinding.setValue(value);
    }
  }
}

/**
 * Represents a binding between the directive instance and node instance.
 */
class DirectivePropertyBinding {
  /// Associated NodePropertyBinding
  final NodePropertyBinding nodeBinding;
  /// Directive instance
  final Object directive;

  /**
   * Directive instance getter function representing the `directiveExpression`
   *
   *     @Directive({ bind: const {'nodeProperty': 'directiveExpression'}})
   */
  final Getter getter;

  /// Directive instance setter function. See [getter].
  final Setter setter;

  /**
   * Directives `directiveReactionMethod` which needs to be called when `directiveExpression`
   * changes. This is a way to set up [Watch]es in a declarative manner.
   *
   *     @Directive({ observe: const {'directiveExpression': 'directiveReactionMethod'}})
   */
  final ReactionFn reactionFn;
  final String watchExp;
  /// The [Watch] if the directive needs to be observed. This is either from [Directive.bind]
  /// or [Directive.observe] annotation.
  Watch _watch;

  /// Last value from the watch. Needed to stop circular updates.
  var _lastValue;

  DirectivePropertyBinding(
      Scope scope,
      this.nodeBinding,
      this.directive,
      this.getter,
      this.setter,
      this.watchExp,
      this.reactionFn)
  {
    if (watchExp != null && watchExp.isNotEmpty) {
      scope.watch(watchExp, (_, __) => check(), context: directive);
    }
  }

  /// called by [Scope.watch]
  check() {
    setValue(getter(directive));
  }

  /// Notify binding of a change to value. This change could come from [Watch] or from
  /// [NodePropertyBinding]
  setValue(value) {
    var lastValue = _lastValue;
    if (same(value, lastValue)) return;
    _lastValue = value;
    if (nodeBinding != null) nodeBinding.setValue(value);
    if (setter != null) setter(directive, value);
    if (reactionFn != null) reactionFn(value, lastValue);
  }
}
