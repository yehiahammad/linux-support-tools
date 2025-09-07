# linux-support-tools
#1 ssc-to-sos-conv.sh script:
The ssc-to-sos-conv.sh script is used to convert an uncompressed SUSE supportconfig file to look like Red Hat's sosreport style of report utility.
Simply unpack the SUSE supportconfig, then change inside the directory and execute the following:
```bash
# tar xvf scc_<HOSTNAME>.txz
```
Change into the supportconfig directory:
```bash
# cd scc_<HOSTNAME>
```
Execute the script to split the *.txt files into the output-directory:
```bash
# sh ~/ssc-to-sos-conv.sh <output-directory>
```

#2 sync_packages.sh script:
Create a text file called desired_packages.txt in the same path as the sync_packages.sh script.
Add the packages with their versions and architectures you wish to match to.
Change the permissions of the script:
```bash
# chmod +x sync_packages.sh
```
Excute the script:
```bash
# ./sync_packages.sh
```
