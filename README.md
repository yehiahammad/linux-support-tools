# linux-support-tools
#1 ssc-to-sos-conv.sh script:
The ssc-to-sos-conv.sh script is used to convert an uncompressed SUSE supportconfig file to look like Red Hat's sosreport style of report utility.
Simply unpack the SUSE supportconfig, then change inside the directory and execute the following:
# tar xvf scc_<HOSTNAME>.txz
Change into the supportconfig directory:
# cd scc_<HOSTNAME>
Execute the script to split the *.txt files into the output-directory:
# sh ~/ssc-to-sos-conv.sh <output-directory>
