import io
import binascii
import os.path
import uuid

from typing import Any, Dict, Optional, Type, TypeVar, List
from pathlib import Path
from ovmfvartool import (
    FirmwareVolumeHeader,
    VariableStoreHeader,
    AuthenticatedVariable,
    resolveUUID,
    UEFITime,
)

import test_driver.machine


TEfiVariable = TypeVar("TEfiVariable", bound="EfiVariable")


class EfiVariable(AuthenticatedVariable):
    class Flags:
        NON_VOLATILE = 0x1
        BOOTSERVICE_ACCESS = 0x2
        RUNTIME_ACCESS = 0x4
        TIME_BASED_AUTHENTICATED_WRITE_ACCESS = 0x20

    class State:
        VAR_HEADER_VALID_ONLY = 0x7F ^ 0xFF
        VAR_ADDED = 0x40

    volatile = False
    boot_access = False
    runtime_access = False
    hardware_error_record = False
    authenticated_write_access = False
    time_based_authenticated_write_access = False
    append_write = False

    def __init__(
        self,
        vendor_uuid: Optional[uuid.UUID] = None,
        name: Optional[str] = None,
        data: Optional[bytes] = None,
        state: Optional[int] = None,
        flags: Optional[int] = None,
    ) -> None:
        self.magic = 0x55AA
        self.reserved1 = 0
        self.monotonicCount = 0
        self.timestamp = UEFITime()
        self.pubKeyIdx = 0
        self.state = 0
        self.flags = 0

        if state:
            self.state = state ^ 0xFF

        if flags:
            self.flags = flags

        if vendor_uuid:
            self.vendorUUID = vendor_uuid

        if name:
            self.name = name
            self.nameLen = len(name) * 2 + 2

        if data:
            self.data = data
            self.dataLen = len(data)

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
    def deserialize(cls: Type[TEfiVariable], f: Any) -> TEfiVariable:
        # pylint: disable=no-member
        # false positive https://github.com/PyCQA/pylint/issues/981
        ret = super(EfiVariable, cls).deserialize(f)
        if ret:
            ret._read_flags()
        return ret

    @classmethod
    def deserializeFromDocument(
        cls: Type[TEfiVariable], vendorID: str, name: str, doc: Any
    ) -> TEfiVariable:
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
                print("read data")
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
            print("not found")
            print(self.state_path)
            return None

    def create_empty(self) -> None:
        self._assert_stopped()

        if os.path.exists(self.state_path):
            raise Exception("OVMF variables store exists")

        with open(self.state_path, "wb") as fo:
            fm = io.BytesIO(b"\xFF" * (528 * 1024))
            fm.write(FirmwareVolumeHeader.create().serialize())
            fm.write(VariableStoreHeader.create().serialize())

            fm.seek(0x41000)
            fm.write(
                binascii.unhexlify(
                    b"2b29589e687c7d49a0ce6500fd9f1b952caf2c64feffffffe00f000000000000"
                )
            )
            fm.seek(0)
            fo.write(fm.read())

            print("wrote empty vars")
            print(self.state_path)

    def write(self, add: List[EfiVariable]) -> None:
        self._assert_stopped()

        variables = self.read_content()
        if not variables:
            variables = {}

        for var in add:
            k = resolveUUID(var.vendorUUID)
            variables.setdefault(k, {})
            variables[k][var.name] = var

        with open(self.state_path, "wb") as fo:
            fm = io.BytesIO(b"\xFF" * (528 * 1024))
            fm.write(FirmwareVolumeHeader.create().serialize())
            fm.write(VariableStoreHeader.create().serialize())

            for _, vendor in variables.items():
                for _, v in vendor.items():
                    fm.write(v.serialize())
                    if fm.tell() % 4:
                        fm.write(b"\xFF" * (4 - (fm.tell() % 4)))
                    assert (fm.tell() % 4) == 0

            fm.seek(0x41000)
            fm.write(
                binascii.unhexlify(
                    b"2b29589e687c7d49a0ce6500fd9f1b952caf2c64feffffffe00f000000000000"
                )
            )
            fm.seek(0)
            fo.write(fm.read())

            print("wrote vars")
            print(self.state_path)


class EfiGuid:
    from ovmfvartool import (
        gEfiSystemNvDataFvGuid,
        gEfiAuthenticatedVariableGuid,
        gEdkiiVarErrorFlagGuid,
        gEfiMemoryTypeInformationGuid,
        gMtcVendorGuid,
        gEfiGlobalVariableGuid,
        gEfiIScsiInitiatorNameProtocolGuid,
        gEfiIp4Config2ProtocolGuid,
        gEfiImageSecurityDatabaseGuid,
        gEfiSecureBootEnableDisableGuid,
        gEfiCustomModeEnableGuid,
        gIScsiConfigGuid,
        gEfiCertDbGuid,
        gMicrosoftVendorGuid,
        gEfiVendorKeysNvGuid,
        mBmHardDriveBootVariableGuid,
    )
