// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

part 'runtime.g.dart';

WasmRuntime wasmRuntimeFactory(
  WasmRuntimeDelegate delegate,
) {
  return WasmRuntime._(delegate);
}

abstract class WasmRuntimeDelegate {
  // TODO: this should only contain the wasmer bindings.
  WasmRuntimeBindings get lib;

  Exception trapExceptionFactory(
    String message,
  );

  void finalizeEngine(Object owner, Pointer<WasmerEngine> ptr);

  void finalizeStore(Object owner, Pointer<WasmerStore> ptr);

  void finalizeModule(Object owner, Pointer<WasmerModule> ptr);

  void finalizeTrap(Object owner, Pointer<WasmerTrap> ptr);

  void finalizeInstance(Object owner, Pointer<WasmerInstance> ptr);

  void finalizeMemorytype(Object owner, Pointer<WasmerMemorytype> ptr);

  void finalizeMemory(Object owner, Pointer<WasmerMemory> ptr);

  void finalizeFunc(Object owner, Pointer<WasmerFunc> ptr);

  void finalizeGlobal(Object owner, Pointer<WasmerGlobal> ptr);
}

class WasmRuntime {
  final Map<String, _WasmTrapsEntry> _traps;
  late final Pointer<WasmerEngine> engine;
  late final Pointer<WasmerStore> store;
  final WasmRuntimeDelegate delegate;

  WasmRuntime._(this.delegate) : _traps = <String, _WasmTrapsEntry>{} {
    engine = _checkNotEqual(
      bindings.engine_new(),
      nullptr,
      'Failed to initialize Wasm engine.',
    );
    delegate.finalizeEngine(this, engine);
    store = _checkNotEqual(
      bindings.store_new(engine),
      nullptr,
      'Failed to create Wasm store.',
    );
    delegate.finalizeStore(this, store);
  }

  WasmRuntimeBindings get bindings {
    return delegate.lib;
  }

  Pointer<WasmerModule> compile(Object owner, Uint8List data) {
    final dataPtr = calloc<Uint8>(data.length);
    for (var i = 0; i < data.length; ++i) {
      dataPtr[i] = data[i];
    }
    final dataVec = calloc<WasmerByteVec>();
    dataVec.ref.data = dataPtr;
    dataVec.ref.length = data.length;

    final modulePtr = bindings.module_new(store, dataVec);

    calloc
      ..free(dataPtr)
      ..free(dataVec);

    _checkNotEqual(modulePtr, nullptr, 'Wasm module compilation failed.');
    delegate.finalizeModule(owner, modulePtr);
    return modulePtr;
  }

  Pointer _externTypeToFuncOrGlobalType(
    int kind,
    Pointer<WasmerExterntype> extern,
  ) {
    if (kind == wasmerExternKindFunction) {
      return bindings.externtype_as_functype(extern);
    } else if (kind == wasmerExternKindGlobal) {
      return bindings.externtype_as_globaltype(extern);
    }
    return nullptr;
  }

  List<WasmExportDescriptor> exportDescriptors(Pointer<WasmerModule> module) {
    var exportsVec = calloc<WasmerExporttypeVec>();
    bindings.module_exports(module, exportsVec);
    var exps = <WasmExportDescriptor>[];
    for (var i = 0; i < exportsVec.ref.length; ++i) {
      final exp = exportsVec.ref.data[i];
      final extern = bindings.exporttype_type(exp);
      final kind = bindings.externtype_kind(extern);
      final name = bindings.exporttype_name(exp).ref.toString();
      final type = _externTypeToFuncOrGlobalType(kind, extern);
      exps.add(
        WasmExportDescriptor._(
          kind,
          name,
          type,
          _getImportExportString(kind, name, type),
        ),
      );
    }
    calloc.free(exportsVec);
    return exps;
  }

  List<WasmImportDescriptor> importDescriptors(Pointer<WasmerModule> module) {
    var importsVec = calloc<WasmerImporttypeVec>();
    bindings.module_imports(module, importsVec);
    var imps = <WasmImportDescriptor>[];
    for (var i = 0; i < importsVec.ref.length; ++i) {
      final imp = importsVec.ref.data[i];
      final extern = bindings.importtype_type(imp);
      final kind = bindings.externtype_kind(extern);
      final moduleName = bindings.importtype_module(imp).ref.toString();
      final name = bindings.importtype_name(imp).ref.toString();
      final type = _externTypeToFuncOrGlobalType(kind, extern);
      imps.add(
        WasmImportDescriptor._(
          kind,
          moduleName,
          name,
          type,
          _getImportExportString(kind, '$moduleName::$name', type),
        ),
      );
    }
    calloc.free(importsVec);
    return imps;
  }

  void maybeThrowTrap(Pointer<WasmerTrap> trap, String source) {
    if (trap != nullptr) {
      // There are 2 kinds of trap, and their memory is managed differently.
      // Traps created in the newTrap method below are stored in the traps map
      // with a corresponding exception, and their memory is managed using a
      // finalizer on the _WasmTrapsEntry. Traps can also be created by WASM
      // code, and in that case we delete them in this function.
      final trapMessage = calloc<WasmerByteVec>();
      bindings.trap_message(trap, trapMessage);
      final message = trapMessage.ref.toString();
      bindings.byte_vec_delete(trapMessage);
      calloc.free(trapMessage);
      final entry = _traps.remove(message);
      if (entry == null) {
        // TODO(#87): Report a full stack trace to the user.
        throw delegate.trapExceptionFactory(message);
      }
      // ignore: only_throw_errors
      throw entry.exception;
    }
  }

  Pointer<WasmerInstance> instantiate(
    Object owner,
    Pointer<WasmerModule> module,
    Pointer<WasmerExternVec> imports,
  ) {
    var trap = calloc<Pointer<WasmerTrap>>()..value = nullptr;
    var inst = bindings.instance_new(store, module, imports, trap);
    maybeThrowTrap(trap.value, 'module initialization function');
    calloc.free(trap);
    _checkNotEqual(inst, nullptr, 'Wasm module instantiation failed.');
    delegate.finalizeInstance(owner, inst);
    return inst;
  }

  // Clean up the exports after use, with deleteExports.
  Pointer<WasmerExternVec> exports(Pointer<WasmerInstance> instancePtr) {
    var exports = calloc<WasmerExternVec>();
    bindings.instance_exports(instancePtr, exports);
    return exports;
  }

  void deleteExports(Pointer<WasmerExternVec> exports) {
    bindings.extern_vec_delete(exports);
    calloc.free(exports);
  }

  int externKind(Pointer<WasmerExtern> extern) => bindings.extern_kind(extern);

  Pointer<WasmerFunc> externToFunction(Pointer<WasmerExtern> extern) =>
      bindings.extern_as_func(extern);

  Pointer<WasmerExtern> functionToExtern(Pointer<WasmerFunc> func) =>
      bindings.func_as_extern(func);

  List<int> getArgTypes(Pointer<WasmerFunctype> funcType) {
    var types = <int>[];
    var args = bindings.functype_params(funcType);
    for (var i = 0; i < args.ref.length; ++i) {
      types.add(bindings.valtype_kind(args.ref.data[i]));
    }
    return types;
  }

  int getReturnType(Pointer<WasmerFunctype> funcType) {
    var rets = bindings.functype_results(funcType);
    if (rets.ref.length == 0) {
      return wasmerValKindVoid;
    } else if (rets.ref.length > 1) {
      throw _WasmRuntimeErrorImpl('Multiple return values are not supported');
    }
    return bindings.valtype_kind(rets.ref.data[0]);
  }

  void call(
    Pointer<WasmerFunc> func,
    Pointer<WasmerValVec> args,
    Pointer<WasmerValVec> results,
    String source,
  ) {
    maybeThrowTrap(bindings.func_call(func, args, results), source);
  }

  Pointer<WasmerMemory> externToMemory(Pointer<WasmerExtern> extern) =>
      bindings.extern_as_memory(extern);

  Pointer<WasmerExtern> memoryToExtern(Pointer<WasmerMemory> memory) =>
      bindings.memory_as_extern(memory);

  Pointer<WasmerMemory> newMemory(
    Object owner,
    int pages,
    int? maxPages,
  ) {
    var limPtr = calloc<WasmerLimits>();
    limPtr.ref.min = pages;
    limPtr.ref.max = maxPages ?? wasmLimitsMaxDefault;
    var memType = bindings.memorytype_new(limPtr);
    calloc.free(limPtr);
    _checkNotEqual(memType, nullptr, 'Failed to create memory type.');
    delegate.finalizeMemorytype(owner, memType);
    var memory = _checkNotEqual(
      bindings.memory_new(store, memType),
      nullptr,
      'Failed to create memory.',
    );
    delegate.finalizeMemory(owner, memory);
    return memory;
  }

  void growMemory(Pointer<WasmerMemory> memory, int deltaPages) {
    _checkNotEqual(
      bindings.memory_grow(memory, deltaPages),
      0,
      'Failed to grow memory.',
    );
  }

  int memoryLength(Pointer<WasmerMemory> memory) {
    return bindings.memory_size(memory);
  }

  Uint8List memoryView(Pointer<WasmerMemory> memory) {
    return bindings.memory_data(memory).asTypedList(
          bindings.memory_data_size(memory),
        );
  }

  Pointer<WasmerFunc> newFunc(
    Object owner,
    Pointer<WasmerFunctype> funcType,
    Pointer func,
    Pointer env,
    Pointer finalizer,
  ) {
    var f = bindings.func_new_with_env(
      store,
      funcType,
      func.cast(),
      env.cast(),
      finalizer.cast(),
    );
    _checkNotEqual(f, nullptr, 'Failed to create function.');
    delegate.finalizeFunc(owner, f);
    return f;
  }

  Pointer<WasmerVal> newValue(int type, dynamic val) {
    final wasmerVal = calloc<WasmerVal>();
    if (!wasmerVal.ref.fill(type, val)) {
      throw _WasmRuntimeErrorImpl(
        'Bad value for WASM type: ${wasmerValKindName(type)}',
      );
    }
    return wasmerVal;
  }

  Pointer<WasmerGlobal> newGlobal(
    Object owner,
    Pointer<WasmerGlobaltype> globalType,
    dynamic val,
  ) {
    final wasmerVal = newValue(getGlobalKind(globalType), val);
    final global = bindings.global_new(store, globalType, wasmerVal);
    delegate.finalizeGlobal(owner, global);
    calloc.free(wasmerVal);
    return global;
  }

  Pointer<WasmerGlobaltype> getGlobalType(Pointer<WasmerGlobal> global) =>
      bindings.global_type(global);

  int getGlobalKind(Pointer<WasmerGlobaltype> globalType) =>
      bindings.valtype_kind(bindings.globaltype_content(globalType));

  int getGlobalMut(Pointer<WasmerGlobaltype> globalType) =>
      bindings.globaltype_mutability(globalType);

  Pointer<WasmerGlobal> externToGlobal(Pointer<WasmerExtern> extern) =>
      bindings.extern_as_global(extern);

  Pointer<WasmerExtern> globalToExtern(Pointer<WasmerGlobal> global) =>
      bindings.global_as_extern(global);

  dynamic globalGet(Pointer<WasmerGlobal> global, int type) {
    final wasmerVal = newValue(type, 0);
    bindings.global_get(global, wasmerVal);
    final result = wasmerVal.ref.toDynamic;
    calloc.free(wasmerVal);
    return result;
  }

  void globalSet(Pointer<WasmerGlobal> global, int type, dynamic val) {
    final wasmerVal = newValue(type, val);
    bindings.global_set(global, wasmerVal);
    calloc.free(wasmerVal);
  }

  Pointer<WasmerByteVec> _allocateString(String str) {
    // Allocates both the WasmerByteVec and its internal byte list using calloc.
    // The caller is responsible for freeing both.
    final strList = utf8.encode(str);
    final bytes = calloc<WasmerByteVec>();
    bytes.ref.data = calloc<Uint8>(strList.length);
    for (var i = 0; i < strList.length; ++i) {
      bytes.ref.data[i] = strList[i];
    }
    bytes.ref.length = strList.length;
    return bytes;
  }

  Pointer<WasmerTrap> newTrap(Object exception) {
    final msg = 'dart:${exception.hashCode.toRadixString(36)}';
    final bytes = _allocateString(msg);
    var trap = bindings.trap_new(store, bytes);
    calloc
      ..free(bytes.ref.data)
      ..free(bytes);
    _checkNotEqual(trap, nullptr, 'Failed to create trap.');
    var entry = _WasmTrapsEntry(exception);
    delegate.finalizeTrap(entry, trap);
    _traps[msg] = entry;
    return trap;
  }

  Pointer<WasmerWasiConfig> newWasiConfig() {
    var name = calloc<Uint8>();
    name[0] = 0;
    var config = bindings.wasi_config_new(name);
    calloc.free(name);
    return _checkNotEqual(config, nullptr, 'Failed to create WASI config.');
  }

  void captureWasiStdout(Pointer<WasmerWasiConfig> config) {
    bindings.wasi_config_capture_stdout(config);
  }

  void captureWasiStderr(Pointer<WasmerWasiConfig> config) {
    bindings.wasi_config_capture_stderr(config);
  }

  Pointer<WasmerWasiEnv> newWasiEnv(Pointer<WasmerWasiConfig> config) =>
      _checkNotEqual(
        bindings.wasi_env_new(config),
        nullptr,
        'Failed to create WASI environment.',
      );

  void getWasiImports(
    Pointer<WasmerModule> mod,
    Pointer<WasmerWasiEnv> env,
    Pointer<WasmerExternVec> imports,
  ) {
    _checkNotEqual(
      bindings.wasi_get_imports(store, mod, env, imports),
      0,
      'Failed to fill WASI imports.',
    );
  }

  Stream<List<int>> getWasiStdoutStream(Pointer<WasmerWasiEnv> env) {
    return Stream.fromIterable(
      _WasiStreamIterable(env, bindings.wasi_env_read_stdout),
    );
  }

  Stream<List<int>> getWasiStderrStream(Pointer<WasmerWasiEnv> env) {
    return Stream.fromIterable(
      _WasiStreamIterable(env, bindings.wasi_env_read_stderr),
    );
  }

  String _getLastError() {
    var length = bindings.wasmer_last_error_length();
    var buf = calloc<Uint8>(length);
    bindings.wasmer_last_error_message(buf, length);
    var message = utf8.decode(buf.asTypedList(length));
    calloc.free(buf);
    return message;
  }

  T _checkNotEqual<T>(T x, T y, String errorMessage) {
    if (x == y) {
      throw _WasmRuntimeErrorImpl('$errorMessage\n${_getLastError()}'.trim());
    }
    return x;
  }

  String _getImportExportString(
    int kind,
    String name,
    Pointer type,
  ) {
    final kindName = wasmerExternKindName(kind);
    if (kind == wasmerExternKindFunction) {
      final funcType = type as Pointer<WasmerFunctype>;
      final sig = getSignatureString(
        name,
        getArgTypes(funcType),
        getReturnType(funcType),
      );
      return '$kindName: $sig';
    } else if (kind == wasmerExternKindGlobal) {
      final globalType = type as Pointer<WasmerGlobaltype>;
      final typeName = wasmerValKindName(getGlobalKind(globalType));
      final mutName = wasmerMutabilityName(getGlobalMut(globalType));
      return '$kindName: $mutName $typeName $name';
    } else {
      return '$kindName: $name';
    }
  }
}

class WasmImportDescriptor {
  final int kind;
  final String moduleName;
  final String name;
  final Pointer type;
  final String description;

  const WasmImportDescriptor._(
    this.kind,
    this.moduleName,
    this.name,
    this.type,
    this.description,
  );

  @override
  String toString() => description;
}

class WasmExportDescriptor {
  final int kind;
  final String name;
  final Pointer type;
  final String description;

  const WasmExportDescriptor._(
    this.kind,
    this.name,
    this.type,
    this.description,
  );

  @override
  String toString() => description;
}

class _WasmTrapsEntry {
  final Object exception;

  _WasmTrapsEntry(this.exception);
}

class _WasiStreamIterator implements Iterator<List<int>> {
  static const int _bufferLength = 1024;
  final Pointer<Uint8> _buf = calloc<Uint8>(_bufferLength);
  final Pointer<WasmerWasiEnv> _env;
  final Function _reader;
  int _length = 0;

  _WasiStreamIterator(this._env, this._reader);

  @override
  bool moveNext() {
    _length = _reader(_env, _buf, _bufferLength) as int;
    return _length >= 0;
  }

  @override
  List<int> get current => _buf.asTypedList(_length);
}

class _WasiStreamIterable extends Iterable<List<int>> {
  final Pointer<WasmerWasiEnv> _env;
  final Function _reader;

  _WasiStreamIterable(this._env, this._reader);

  @override
  Iterator<List<int>> get iterator => _WasiStreamIterator(_env, _reader);
}

String getSignatureString(
  String name,
  List<int> argTypes,
  int returnType,
) =>
    '${wasmerValKindName(returnType)} '
    '$name(${argTypes.map(wasmerValKindName).join(', ')})';

class _WasmRuntimeErrorImpl extends Error {
  final String message;

  _WasmRuntimeErrorImpl(
    this.message,
  ) : assert(message.trim() == message);

  @override
  String toString() => 'WasmRuntimeError: $message';
}

// wasm_valkind_enum
const int wasmerValKindI32 = 0;
const int wasmerValKindI64 = 1;
const int wasmerValKindF32 = 2;
const int wasmerValKindF64 = 3;
// The void tag is not part of the C API. It's used to represent the return type
// of a void function.
const int wasmerValKindVoid = -1;

// wasm_externkind_enum
const int wasmerExternKindFunction = 0;
const int wasmerExternKindGlobal = 1;
const int wasmerExternKindTable = 2;
const int wasmerExternKindMemory = 3;

// wasm_mutability_enum
const int wasmerMutabilityConst = 0;
const int wasmerMutabilityVar = 1;

String wasmerExternKindName(int kind) {
  switch (kind) {
    case wasmerExternKindFunction:
      return 'function';
    case wasmerExternKindGlobal:
      return 'global';
    case wasmerExternKindTable:
      return 'table';
    case wasmerExternKindMemory:
      return 'memory';
    default:
      return 'unknown';
  }
}

String wasmerValKindName(int kind) {
  switch (kind) {
    case wasmerValKindI32:
      return 'int32';
    case wasmerValKindI64:
      return 'int64';
    case wasmerValKindF32:
      return 'float32';
    case wasmerValKindF64:
      return 'float64';
    case wasmerValKindVoid:
      return 'void';
    default:
      return 'unknown';
  }
}

String wasmerMutabilityName(int kind) {
  switch (kind) {
    case wasmerMutabilityConst:
      return 'const';
    case wasmerMutabilityVar:
      return 'var';
    default:
      return 'unknown';
  }
}

// wasm_val_t
class WasmerVal extends Struct {
  // wasm_valkind_t
  @Uint8()
  external int kind;

  // This is a union of int32_t, int64_t, float, and double. The kind determines
  // which type it is. It's declared as an int64_t because that's large enough
  // to hold all the types. We use ByteData to get the other types.
  @Int64()
  external int value;

  int get _off32 => Endian.host == Endian.little ? 0 : 4;

  int get i64 => value;

  ByteData get _getterBytes => ByteData(8)..setInt64(0, value, Endian.host);

  int get i32 => _getterBytes.getInt32(_off32, Endian.host);

  double get f32 => _getterBytes.getFloat32(_off32, Endian.host);

  double get f64 => _getterBytes.getFloat64(0, Endian.host);

  set i64(int val) => value = val;

  set _val(ByteData bytes) => value = bytes.getInt64(0, Endian.host);

  set i32(int val) => _val = ByteData(8)..setInt32(_off32, val, Endian.host);

  set f32(num val) =>
      _val = ByteData(8)..setFloat32(_off32, val as double, Endian.host);

  set f64(num val) =>
      _val = ByteData(8)..setFloat64(0, val as double, Endian.host);

  bool get isI32 => kind == wasmerValKindI32;

  bool get isI64 => kind == wasmerValKindI64;

  bool get isF32 => kind == wasmerValKindF32;

  bool get isF64 => kind == wasmerValKindF64;

  dynamic get toDynamic {
    switch (kind) {
      case wasmerValKindI32:
        return i32;
      case wasmerValKindI64:
        return i64;
      case wasmerValKindF32:
        return f32;
      case wasmerValKindF64:
        return f64;
    }
  }

  bool fill(int _kind, dynamic val) {
    kind = _kind;
    switch (kind) {
      case wasmerValKindI32:
        if (val is! int) return false;
        i32 = val;
        return true;
      case wasmerValKindI64:
        if (val is! int) return false;
        i64 = val;
        return true;
      case wasmerValKindF32:
        if (val is! num) return false;
        f32 = val;
        return true;
      case wasmerValKindF64:
        if (val is! num) return false;
        f64 = val;
        return true;
    }
    return false;
  }
}

// wasmer_limits_t
class WasmerLimits extends Struct {
  @Uint32()
  external int min;

  @Uint32()
  external int max;
}

// Default maximum, which indicates no upper limit.
const int wasmLimitsMaxDefault = 0xffffffff;
