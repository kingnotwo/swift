//===-- Tensor.swift ------------------------------------------*- swift -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This is the core Tensor abstraction, which is conceptually equivalent to a
// NumPy ndarray.  It carries no rank information in its static type, so it can
// be used by model developers who don't want it.
//
//===----------------------------------------------------------------------===//

// NOTE: Pretty much everything here is marked @_inlineable/@_versioned.  This
// causes the body to be serialized into the generated Swift module, which
// allows it to be inlined into the user's code during deabstraction.  This is
// really gross, and will get better one way or the other, through compiler
// changes.

import CTensorFlow

//===----------------------------------------------------------------------===//
// Tensor type
//===----------------------------------------------------------------------===//

public struct Tensor<Unit : AccelerableTensorUnit> {
  /// A tensor just contains a TensorHandle under the covers.  This is public to
  /// allow user defined ops, but shouldn't normally be used otherwise.
  public let handle: TensorHandle<Unit>

  @_inlineable
  public init(_ handle: TensorHandle<Unit>) {
    self.handle = handle
  }
}

//===----------------------------------------------------------------------===//
// Compiler intrinsics
//===----------------------------------------------------------------------===//
//
// By default, when a tensor value is implicitly passed between host and tensor
// code, the partitioning pass will generate a warning.  Users can indicate that
// they are doing something intentional by using these methods, which silences
// the warning.
//
// TODO: These would be nicer if defined as builtins rather than being "well
// known functions".

@_versioned @inline(never)
@_silgen_name("__tf_send")
func _TFSend<Unit>(_ handle: TensorHandle<Unit>) -> TensorHandle<Unit> {
  return handle
}

@_versioned @inline(never)
@_silgen_name("__tf_receive")
func _TFReceive<Unit>(_ handle: TensorHandle<Unit>) -> TensorHandle<Unit> {
  return handle
}

@_versioned @inline(never)
@_silgen_name("__tf_scalarize")
func _TFScalarize<Unit>(_ handle: TensorHandle<Unit>) -> Unit? {
  return handle.makeHostCopy().scalar
}

//===----------------------------------------------------------------------===//
// Memory transfer markers
//===----------------------------------------------------------------------===//

/// TODO: Remove when send/receive semantics gets revisited.
public extension Tensor {
  @_inlineable
  func toDevice() -> Tensor {
    return Tensor(_TFSend(handle))
  }

  @_inlineable
  func toHost() -> Tensor {
    return Tensor(_TFReceive(handle))
  }
}

//===----------------------------------------------------------------------===//
// Initialization
//===----------------------------------------------------------------------===//

extension Tensor where Unit : Numeric {
  /// Perform an element conversion from Tensor<U> to Tensor<T>.
  @_inlineable // make @_inlineable when implemented.
  public init<FromType : Numeric>(_ other: Tensor<FromType>) {
    self.init(#tfop("Cast", "td:t", other.handle))
    //self = Tensor<Unit>(#tfop("Cast", "td:t", other.handle))
  }
}

public extension Tensor {
  /// Initialize a tensor with a unit representing a scalar value.
  @_inlineable
  init(_ value: Unit) {
    self.init(#tfop("tfc.scalarToTensor", "s:t", value))
  }

  /// Initialize a tensor with an array representing a vector.
  @_inlineable
  init(_ vector: [Unit]) {
    self.init(shape: [vector.count], units: vector)
  }

  /// Initialize a tensor with an array of arrays representing a matrix.
  ///
  /// - Precondition: The number of elements in each sub-dimensional array in
  ///   the array must be equal.
  @_inlineable
  init(_ matrix: [[Unit]]) {
    /// Sanity check
    guard let firstRow = matrix.first else {
      preconditionFailure("The first dimension is empty. Cannot infer shape.")
    }
    /// Now we make assumption about the shape.
    let rowCount = matrix.count, columnCount = firstRow.count
    let contiguousSize = rowCount * columnCount
    let byteSize = contiguousSize * MemoryLayout<Unit>.stride
    /// Check rest dimensions.
    for row in matrix.dropFirst() {
      precondition(row.count == columnCount,
                   "Each dimension must have equal number of subdimensions.")
    }
    /// Initialize tensor and copy data.
    /// We don't want to delegate initialization to `init(shape:units:)`
    /// because flattening `matrix` to an array is unnecessary cost.
    let cTensor = TF_AllocateTensor(Unit.cDataType,
                                    [Int64(rowCount), Int64(columnCount)], 2,
                                    byteSize)
    let status = TF_NewStatus()
    let addr = TF_TensorData(cTensor).assumingMemoryBound(to: Unit.self)
    /// Copy to TF_Tensor memory, one row at a time.
    for (i, row) in matrix.enumerated() {
      row.withUnsafeBufferPointer { ptr in
        addr.advanced(by: i * columnCount).assign(from: ptr.baseAddress!,
                                                  count: columnCount)
      }
    }
    /// Create handle and we are done.
    let cHandle = TFE_NewTensorHandle(cTensor, status)
    checkOk(status)
    TF_DeleteStatus(status)
    TF_DeleteTensor(cTensor)
    self.init(TensorHandle(cTensorHandle: cHandle!))
  }

  /// Initialize a tensor with arbitrary shape.
  /// - Precondition: The number of units should be the same as the
  /// product of all of shape's dimensions.
  @_inlineable
  init(shape: [Int], units: [Unit]) {
    let contiguousSize = shape.reduce(1, *)
    let byteSize = contiguousSize * MemoryLayout<Unit>.stride
    precondition(units.count == contiguousSize, """
      The number of units doesn't match the shape.
      """)
    let cTensor = TF_AllocateTensor(Unit.cDataType,
                                    shape.map(Int64.init),
                                    Int32(shape.count),
                                    byteSize)
    let status = TF_NewStatus()
    /// Copy data
    let addr = TF_TensorData(cTensor).assumingMemoryBound(to: Unit.self)
    units.withUnsafeBufferPointer { ptr in
      addr.assign(from: ptr.baseAddress!, count: contiguousSize)
    }

    /// Create handle and we are done
    let cHandle = TFE_NewTensorHandle(cTensor, status)
    checkOk(status)
    TF_DeleteStatus(status)
    TF_DeleteTensor(cTensor)
    self.init(TensorHandle(cTensorHandle: cHandle!))
  }

  @_inlineable
  init(shape: [Int], repeating repeatedValue: Unit) {
    let contiguousSize = shape.reduce(1, *)
    let byteSize = contiguousSize * MemoryLayout<Unit>.stride
    let cTensor = TF_AllocateTensor(Unit.cDataType,
                                    shape.map(Int64.init),
                                    Int32(shape.count),
                                    byteSize)
    let status = TF_NewStatus()
    /// Copy data
    let addr = TF_TensorData(cTensor).assumingMemoryBound(to: Unit.self)
    /// Memset to `repeatedValue`
    addr.initialize(repeating: repeatedValue, count: contiguousSize)

    /// Create handle and we are done
    let cHandle = TFE_NewTensorHandle(cTensor, status)
    checkOk(status)
    TF_DeleteStatus(status)
    TF_DeleteTensor(cTensor)
    self.init(TensorHandle(cTensorHandle: cHandle!))
  }

  /// Initialize a degenerate tensor with no elements with the specified rank.
  ///
  /// - Precondition: Rank must be greater than 0.
  @_inlineable
  init(emptyWithRank rank: Int) {
    self.init(shape: Array(repeating: 0, count: rank), units: [])
  }
}

//===----------------------------------------------------------------------===//
// Properties
//===----------------------------------------------------------------------===//

public extension Tensor {
  @_inlineable
  var shape: [Int] {
    // TODO: Until we have mandatory deabstraction, we need to force the
    // performance inliner to inline this, even though it is apparently too
    // big to want to do so for performance reasons.
    @inline(__always)
    get {
      return shapeTensor.units
    }
  }

  @_inlineable
  var rank: Int {
    @inline(__always)
    get {
      return rankTensor.scalar!
    }
  }

  @_inlineable
  var unitCount: Int {
    @inline(__always)
    get {
      return unitCountTensor.scalar!
    }
  }
}

//===----------------------------------------------------------------------===//
// Factory methods for numeric tensors
//===----------------------------------------------------------------------===//

public extension Tensor where Unit : Numeric {
  /// Zero initializer, takes a list of dimensions.
  @_inlineable
  static func zeros(shape: [Int]) -> Tensor {
    return Tensor(shape: shape, repeating: 0)
  }

  /// Zero initializer, takes variadic dimensions.
  @_inlineable
  static func zeros(shape: Int...) -> Tensor {
    return zeros(shape: shape)
  }

  /// Ones initializer, takes a list of dimensions.
  @_inlineable
  static func ones(shape: [Int]) -> Tensor {
    return Tensor(shape: shape, repeating: 1)
  }

  /// Ones initializer, takes variadic dimensions.
  @_inlineable
  static func ones(shape: Int...) -> Tensor {
    return ones(shape: shape)
  }

  @inline(never) // make @_inlineable when implemented.
  static func eye(
    rowCount: Int, columnCount: Int? = nil, batchShape: [Int]? = nil
  ) -> Tensor {
    fatalError("FIXME: implement eye")
  }
}

//===----------------------------------------------------------------------===//
// Factory methods for floating point tensors
//===----------------------------------------------------------------------===//

public extension Tensor where Unit : FloatingPoint {
  // def tf.random_normal(shape, mean=0.0, stddev=1.0, dtype=dtypes.float32,
  //                      seed=None, name=None):
  @inline(never) // make @_inlineable when implemented.
  static func randomNormal(
    shape: [Int], mean: Double = 0, stddev: Double = 1
  ) -> Tensor {
    fatalError("FIXME: implement randomNormal")
  }
}

//===----------------------------------------------------------------------===//
// Shape transformations
//===----------------------------------------------------------------------===//

public extension AccelerableTensorUnit {
  /// Broadcast the specified scalar value to be a tensor with the same rank as
  /// the specified other tensor, but with dimension=1 for each rank.
  @inline(never) // make @_inlineable when implemented.
  func broadcast(toRank rank: Int) -> Tensor<Self> {
    fatalError("FIXME: implement scalar broadcast")
  }
}

public extension Tensor {
  @inline(never) // make @_inlineable when implemented.
  func rankLifted(by dimensionCount: Int) -> Tensor {
    fatalError("FIXME: implement broadcast")
  }

  /// Broadcast the specified Tensor to a rank >= its current size, filling in
  /// the new dimensions with rank = 1.
  @inline(never)
  func broadcast(toRank rank: Int) -> Tensor {
    fatalError("FIXME: implement broadcast")
  }

  /// Broadcast self tensor to the same shape as the specified one.
  @inline(never) // make @_inlineable when implemented.
  func broadcast(to other: Tensor) -> Tensor {
    fatalError("FIXME: implement broadcast")
  }

  /// Reshape to the specified shape.
  /// - Precondition: The number of units matches the new shape.
  @_inlineable
  @inline(__always)
  func reshaped(_ newShape: [Int]) -> Tensor {
    return reshaped(Tensor<Int>(newShape))
  }

  /// Reshape to scalar.
  /// - Precondition: The tensor has exactly one unit.
  @_inlineable
  @inline(__always)
  func scalarized() -> Unit {
#if false // FIXME: The partitioner needs to promote array literals.
    guard let scalar = reshaped([]).scalar else {
      preconditionFailure(
        "Only tensors with exactly one unit can be scalarized.")
    }
#else
    // FIXME: This is the inefficient implementation. When the partitioner
    // can promote array literals, replace this with the implementation above.
    guard let scalar = array.scalar else {
      preconditionFailure(
        "Only tensors with exactly one unit can be scalarized.")
    }
#endif
    return scalar
  }

  /// Reshape by removing 1-dimensions. If axes are specified, remove the
  /// specified dimensions, assuming they are 1.
  @_inlineable
  func squeezed(alongAxes axes: Int...) -> Tensor {
    let axesTensor = Tensor<Int>(axes)
    return squeezed(alongAxes: axesTensor)
  }
}

//===----------------------------------------------------------------------===//
// Safe data type conversion
//===----------------------------------------------------------------------===//

public extension Tensor where Unit : Numeric {
  @inline(never)
  init(_ other: Tensor<Bool>) {
    fatalError("FIXME: implement boolean conversion")
  }
}

//===----------------------------------------------------------------------===//
// Scalar conversion
//===----------------------------------------------------------------------===//

public extension Tensor {
  @_inlineable
  var isScalar: Bool {
    return rank == 0
  }

  /// Returns the underlying scalar from a 0-ranked Tensor.
  /// - precondition: Tensor is 0-ranked.
  @_inlineable
  var scalar: Unit? {
    return Unit(self)
  }
}

public extension AccelerableTensorUnit {
  @_inlineable
  init?(_ tensor: Tensor<Self>) {
    guard let scalar = _TFScalarize(tensor.handle) else {
      return nil
    }
    self = scalar
  }
}

//===----------------------------------------------------------------------===//
// Description and visualization
//===----------------------------------------------------------------------===//

/// Make "print(someTensor)" print a pretty form of the tensor.
extension Tensor : CustomStringConvertible {
  public var description: String {
    fatalError("Unimplemented")
  }
}

// Make Tensors show up nicely in the Xcode Playground results sidebar.
extension Tensor : CustomPlaygroundQuickLookable {
  public var customPlaygroundQuickLook: PlaygroundQuickLook {
    fatalError("Unimplemented")
  }
}

//===----------------------------------------------------------------------===//
// Array conversion
//===----------------------------------------------------------------------===//

public extension Tensor {
  @_inlineable
  var array: ShapedArray<Unit> {
    debugLog("Returning a host copy of array.")
    // This is considered to be a well known way to produce a copy to the host,
    // so we never way to produce an "implicit copy to host" warning.
    return toHost().handle.makeHostCopy()
  }

  @_inlineable
  var units: [Unit] {
    return array.units
  }
}