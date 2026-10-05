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
# ./sync_packages.sh desired_packages.txt      # Execute sync with confirmation prompts
# ./sync_packages.sh -d desired_packages.txt   # Preview changes (Dry Run)
# ./sync_packages.sh -y desired_packages.txt   # Execute non-interactively
```

#3 mem_report.py script:
mem_report.py is a lightweight Python utility that parses a Linux /proc/meminfo file and produces a human-readable memory analysis report similar to the free command — while also showing the exact calculations used.
Excute the script:
```bash
# python mem_report.py /proc/meminfo
```

#4 deploy-quay.sh script:
Deploy a quay image registry on your server. Server must be connected to the internet to pull images. Script collects answers from the answers.txt file or you will supply the answers yourself if they do not exist.
Excute the script:
```bash
# chmod +x deploy-quay.sh
# sh deploy-quay.sh
```
