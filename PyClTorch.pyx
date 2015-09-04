from __future__ import print_function

import cython
cimport cython

cimport cpython.array
import array

import PyTorch

cdef extern from "LuaHelper.h":
    cdef struct lua_State
    void *getGlobal(lua_State *L, const char *name1, const char *name2);
    void require(lua_State *L, const char *name)

cdef extern from "THClGeneral.h":
    cdef struct THClState

cdef extern from "THTensor.h":
    cdef struct THFloatTensor

cdef extern from "THClTensor.h":
    cdef struct THClTensor
    THClTensor *THClTensor_newv2(THClState *state, int device)
    THClTensor *THClTensor_newWithSize1d(THClState *state, int device, long size0)
    THClTensor *THClTensor_newWithSize2d(THClState *state, int device, long size0, long size1)
    void THClTensor_retain(THClState *state, THClTensor*self)
    void THClTensor_free(THClState *state, THClTensor *tensor)
    int THClTensor_nDimension(THClState *state, THClTensor *tensor)
    long THClTensor_size(THClState *state, const THClTensor *self, int dim)
    long THClTensor_nElement(THClState *state, const THClTensor *self)

cdef extern from "THClTensorCopy.h":
    void THClTensor_copyFloat(THClState *state, THClTensor *self, THFloatTensor *src)
    void THFloatTensor_copyCl(THClState *state, THFloatTensor *self, THClTensor *src)

cdef extern from "THClTensorMath.h":
    float THClTensor_sumall(THClState *state, THClTensor *self)

cdef extern from "clnnWrapper.h":
    THClState *getState(lua_State *L)
    THClTensor *popClTensor(lua_State *L)
    void pushClTensor(THClState *state, lua_State *L, THClTensor *tensor)

def cyPopClTensor():
    cdef THClTensor *tensorC = popClTensor(globalState.L)
    cdef ClTensor tensor = ClTensor_fromNative(tensorC)
    return tensor

def cyPushClTensor(ClTensor tensor):
    pushClTensor(clGlobalState.state, globalState.L, tensor.native)

cimport PyTorch

cdef class ClTensor(object):
    cdef THClTensor *native

    def __cinit__(ClTensor self, *args, _allocate=True):
#        print('ClTensor.__cinit__')
        if _allocate:
            for arg in args:
                if not isinstance(arg, int):
                    raise Exception('cannot provide arguments to initializer')
            if len(args) == 0:
                self.native = THClTensor_newv2(clGlobalState.state, 0)  # FIXME get device from state
            elif len(args) == 1:
                self.native = THClTensor_newWithSize1d(clGlobalState.state, 0, args[0])  # FIXME get device from state
            elif len(args) == 2:
                self.native = THClTensor_newWithSize2d(clGlobalState.state, 0, args[0], args[1])  # FIXME get device from state
            else:
                raise Exception('Not implemented, len(args)=' + str(len(args)))

    def __dealloc__(ClTensor self):
#        print('ClTensor.__dealloc__')
        THClTensor_free(clGlobalState.state, self.native)

    @staticmethod
    def new():
        return ClTensor()
#        cdef THClTensor *newTensorC = THClTensor_newv2(clGlobalState.state, 0)  # FIXME get device from state
#        return ClTensor_fromNative(newTensorC, False)

    def __repr__(ClTensor self):
        cdef PyTorch._FloatTensor floatTensor = self.float()
        floatRepr = floatTensor.__repr__()
        clRepr = floatRepr.replace('FloatTensor', 'ClTensor')
        return clRepr

    def float(ClTensor self):
        cdef PyTorch._FloatTensor floatTensor = PyTorch._FloatTensor.new()
        cdef PyTorch._FloatTensor size = self.size()
        if size is None:
            return PyTorch._FloatTensor()
        if size.dims() == 0:
            return PyTorch._FloatTensor()
        floatTensor.resize(size)
        THFloatTensor_copyCl(clGlobalState.state, floatTensor.thFloatTensor, self.native)
        return floatTensor

    def copy(ClTensor self, PyTorch._FloatTensor src):
        THClTensor_copyFloat(clGlobalState.state, self.native, src.thFloatTensor)
        return self

    cpdef int dims(ClTensor self):
        return THClTensor_nDimension(clGlobalState.state, self.native)

    def size(ClTensor self):
        cdef int dims = self.dims()
        cdef PyTorch._FloatTensor size
        if dims >= 0:
            size = PyTorch._FloatTensor(dims)
            for d in range(dims):
                size.set1d(d, THClTensor_size(clGlobalState.state, self.native, d))
            return size
        else:
            return None  # not sure how to handle this yet

    def nElement(ClTensor self):
        return THClTensor_nElement(clGlobalState.state, self.native)

    def sum(ClTensor self):
        return THClTensor_sumall(clGlobalState.state, self.native)

cdef ClTensor_fromNative(THClTensor *tensorC, retain=True):
    cdef ClTensor tensor = ClTensor(_allocate=False )
    tensor.native = tensorC
    if retain:
        THClTensor_retain(clGlobalState.state, tensorC)
    return tensor

def FloatTensorToClTensor(PyTorch._FloatTensor floatTensor):
    cdef PyTorch._FloatTensor size = floatTensor.size()
    cdef ClTensor clTensor
    cdef int nElement = floatTensor.nElement()
    if nElement > 0:
        if floatTensor.dims() == 1:
            clTensor = ClTensor(int(size[0]))
        elif floatTensor.dims() == 2:
            clTensor = ClTensor(int(size[0]), int(size[1]))
        elif floatTensor.dims() == 3:
            clTensor = ClTensor(int(size[0]), int(size[1]), int(size[2]))
        elif floatTensor.dims() == 4:
            clTensor = ClTensor(int(size[0]), int(size[1]), int(size[2]), int(size[3]))
        else:
            raise Exception('not implemented')
        clTensor.copy(floatTensor)
        return clTensor
    else:
        return ClTensor()

import floattensor_patch

cdef PyTorch.GlobalState globalState = PyTorch.getGlobalState()

cdef class ClGlobalState(object):
    cdef THClState *state

#    def __cinit__(ClGlobalState self):
#        print('ClGlobalState.__cinit__')

#    def __dealloc__(self):
#        print('ClGlobalState.__dealloc__')

cdef ClGlobalState clGlobalState

def init():
    global clGlobalState
    cdef THClState *state2
    print('initializing PyClTorch...')
    require(globalState.L, 'cltorch')
    require(globalState.L, 'clnn')
    clGlobalState = ClGlobalState()
    clGlobalState.state = getState(globalState.L)
    print(' ... PyClTorch initialized')

init()

