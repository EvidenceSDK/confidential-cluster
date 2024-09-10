# Deployment Guide on TD baremetal host

This guide introduces how to setup an Intel TDX host on Ubuntu 24.04 and a TD VM with
a single node kubernetes cluster running on it.
Follow these instructions to setup Intel TDX host, create a TD image, boot the TD and run a 
kubernetes cluster within the TD.

### Prerequisite

Instructions are relevant for 4th Generation Intel® Xeon® Scalable Processors with activated Intel® TDX 
and all 5th Generation Intel® Xeon® Scalable Processors.

### Setup host

We first need to install a generic Ubuntu 24.04 server image, install necessary packages to turn
the host OS into an Intel TDX-enabled host OS and enable TDX settings in the BIOS.
Detailed instructions to do so can be found here [setup-tdx-host](https://github.com/canonical/tdx?tab=readme-ov-file#setup-tdx-host).

To setup your host, you will essentially need to do this:
```
$ curl https://raw.githubusercontent.com/canonical/tdx/noble-24.04/setup-tdx-host.sh
$ ./setup-tdx-host.sh
```

Once the above step is completed, you will need to reboot your machine and proceed to change the
 BIOS settings to enable TDX.

Go to Socket Configuration > Processor Configuration > TME, TME-MT, TDX.

    * Set `Memory Encryption (TME)` to `Enabled`
    * Set `Total Memory Encryption Bypass` to `Enabled` (Optional setting for best host OS and regular VM performance.)
    * Set `Total Memory Encryption Multi-Tenant (TME-MT)` to `Enabled`
    * Set `TME-MT memory integrity` to `Disabled`
    * Set `Trust Domain Extension (TDX)` to `Enabled`
    * Set `TDX Secure Arbitration Mode Loader (SEAM Loader)` to `Enabled`. (NOTE: This allows loading Intel TDX Loader and Intel TDX Module from the ESP or BIOS.)
    * Set `TME-MT/TDX key split` to a non-zero value

Go to `Socket Configuration > Processor Configuration > Software Guard Extension (SGX)`.

    * Set `SW Guard Extensions (SGX)` to `Enabled`

Save BIOS settings and boot up. Verify that the host has TDX enabled using dmesg command:
```
$ sudo dmesg | grep -i tdx
[    1.523617] Kernel command line: BOOT_IMAGE=/boot/vmlinuz-6.8.0-1004-intel root=UUID=f5524554-48b2-4edf-b0aa-3cebac84b167 ro kvm_intel.tdx=1 nohibernate nomodeset
[    2.551768] virt/tdx: BIOS enabled: private KeyID range [16, 128)
[    2.551773] virt/tdx: Disable ACPI S3. Turn off TDX in the BIOS to use ACPI S3.
[   20.408972] virt/tdx: TDX module: attributes 0x0, vendor_id 0x8086, major_version 2, minor_version 0, build_date 20231112, build_num 635
```

### Setup guest

To setup a guest image with TDX kernel and has all the binaries required for running 
a k3s/k8s cluster, run the following script:

```
./setup_cc.sh
```

After running the script, you should see an image with the name `tdx-guest-ubuntu-24.04-intel.qcow2`
generated in the current directory. The image is setup with user `tdx` with password `123456`.

### Launch a kubernetes cluster

The above step will install a helper script to start a single node kubernetes cluster in the 
home directory for the `tdx` user in the guest image.

The `setup_cc.sh` script should have copied a script called `start-virt.sh` into the current directory.
Use that too ssh into the TD VM:
```
$ ./start-virt.sh -i tdx-guest-ubuntu-24.04-intel.qcow2 
```

Once you have logged in the TD VM, run the following script to start a single node kubernetes cluster:
```
$ sudo -E /home/tdx/create_k8s_node.sh
```
