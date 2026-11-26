KONDEY SCHOOL - FINGERPRINT SYNC (ZKBio Time -> staff portal)

Put this folder on the computer that runs ZKBio Time (192.168.11.20),
for example in C:\KondeySync. Do not change the fingerprint machines.

1. In the staff portal (as admin): Report cards > Settings >
   "Fingerprint machines" > Create sync key. Copy the key.
2. Open config.txt in Notepad and fill in:
     BIOTIME_USER / BIOTIME_PASSWORD  - a ZKBio Time login
     SYNC_KEY                         - the key from step 1
   Save the file.
3. Double-click 1-test.bat. It should end with "Test OK".
4. Right-click 2-install.bat > Run as administrator.
   From now on check-ins are sent every 5 minutes while the computer is on.

To stop: right-click 3-uninstall.bat > Run as administrator.
Problems: open sync.log in this folder and read the last ERROR line.

Keep config.txt private: it contains the ZKBio Time password and the sync key.
The sync key can only add check-ins; replace it in the portal if it is ever shared.
