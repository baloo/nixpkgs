from typing import Any, Dict, Optional, Type, TypeVar
from pathlib import Path
from ovmfvartool import (
    FirmwareVolumeHeader,
    VariableStoreHeader,
    AuthenticatedVariable,
    resolveUUID,
)

import test_driver.machine


T = TypeVar("T", bound="EfiVariable")


class EfiVariable(AuthenticatedVariable):
    volatile = False
    boot_access = False
    runtime_access = False
    hardware_error_record = False
    authenticated_write_access = False
    time_based_authenticated_write_access = False
    append_write = False

    def _read_flags(self) -> None:
        if not (self.flags & 0x1):
            self.volatile = True
        if self.flags & 0x2:
            self.boot_access = True
        if self.flags & 0x4:
            self.runtime_access = True
        if self.flags & 0x8:
            self.hardware_error_record = True
        if self.flags & 0x10:
            self.authenticated_write_access = True
        if self.flags & 0x20:
            self.time_based_authenticated_write_access = True
        if self.flags & 0x40:
            self.append_write = True

        self.flags &= ~(0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40)

    @classmethod
    def deserialize(cls: Type[T], f: Any) -> T:
        # pylint: disable=no-member
        # false positive https://github.com/PyCQA/pylint/issues/981
        ret = super(EfiVariable, cls).deserialize(f)
        if ret:
            ret._read_flags()
        return ret

    @classmethod
    def deserializeFromDocument(cls: Type[T], vendorID: str, name: str, doc: Any) -> T:
        # pylint: disable=no-member
        # false positive https://github.com/PyCQA/pylint/issues/981
        ret = super(EfiVariable, cls).deserializeFromDocument(vendorID, name, doc)
        if ret:
            ret._read_flags()
        return ret


class EfiVars:
    """A container around the ovmf variables"""

    state_path: Path
    machine: "test_driver.machine.Machine"

    def __init__(self, state_path: Path, machine: Any):
        self.state_path = state_path
        self.machine = machine

    def _assert_stopped(self) -> None:
        if self.machine.booted:
            raise Exception(
                "System is currently running and concurrent reads / writes to the OVMF variables is unsupported"
            )

    def read_content(self) -> Optional[Dict[str, Dict[str, EfiVariable]]]:
        self._assert_stopped()
        try:
            with open(self.state_path, "rb") as f:
                fvh = FirmwareVolumeHeader.deserialize(f)
                vsh = VariableStoreHeader.deserialize(f)
                variables: Dict[str, Dict[str, EfiVariable]] = {}

                while True:
                    v = EfiVariable.deserialize(f)
                    if not v:
                        break
                    if v.isDeleted:
                        continue

                    k = resolveUUID(v.vendorUUID)
                    variables.setdefault(k, {})
                    variables[k][v.name] = v

                return variables

        except FileNotFoundError:
            return None
