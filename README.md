# From Dual-Boot, to VM
This repository allows an Ubuntu host to access a Dual-Booted Windows partition via a VM

## Usage

In order to setup this repository, run the following:

```
./setup_1.sh # Required a reboot at the end of the script
./setup_2.sh
```

Now, if you want to run your VM, run

```
./start
```

You can symlink any of {/usr/bin,/usr/local/bin,~/bin}/windows-vm to ./start if you wish to run it from cmdline anywhere.  

If a script fails, the script name with a line number will show where. That will help you recover from the situation, but it would require reading through the scripts to undo what the script already did.
