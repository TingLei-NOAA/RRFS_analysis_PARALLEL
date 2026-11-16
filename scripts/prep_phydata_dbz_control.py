#!/usr/bin/env python3
'''
   This script prepares phy_data.nc for ingestion in FV3-JEDI for radar DA
   Two things are done:
      1) Lower bound of refl is set to 0 dBZ
      2) Reverse vertical index so that index 0 corresponds to the model top
'''
import netCDF4 as nc
import numpy as np
import sys
import time

start_time = time.time()

file_prep = sys.argv[1]
print(f'[{time.strftime("%H:%M:%S")}] Starting processing: {file_prep}', flush=True)

# Read data
read_start = time.time()
nc_file = nc.Dataset(file_prep, 'r+')
refl3d = nc_file.variables['ref_f3d']
print(f'[{time.strftime("%H:%M:%S")}] Open completed in {time.time() - read_start:.2f}s', flush=True)

# Check if this is already been pre-processed and exit
rmin = np.inf
for k in range(refl3d.shape[1]):
    kmin = np.nanmin(refl3d[:, k, :, :])
    if kmin < 0.0:
        rmin = kmin
        break
    rmin = min(rmin, kmin)
if rmin >= 0.0:
    nc_file.close()
    sys.exit(f'Quitting early... {file_prep} seems to already be prepped. ReflMin = {rmin} dbz')

# Reverse vertical order for JEDI
proc_start = time.time()
nk = refl3d.shape[1]
for k in range(nk // 2):
    ktop = nk - 1 - k
    lower = refl3d[:, k, :, :].copy()
    upper = refl3d[:, ktop, :, :].copy()
#cltorg    refl3d[:, k, :, :] = np.maximum(upper, 0.0)
#cltorg    refl3d[:, ktop, :, :] = np.maximum(lower, 0.0)
    refl3d[:, k, :, :] = np.maximum(upper, -35.0)
    refl3d[:, ktop, :, :] = np.maximum(lower, -35.0)

if nk % 2 == 1:
    kmid = nk // 2
#cltorg    refl3d[:, kmid, :, :] = np.maximum(refl3d[:, kmid, :, :], 0.0)
    refl3d[:, kmid, :, :] = np.maximum(refl3d[:, kmid, :, :], -35.0)

# Close file
close_start = time.time()
nc_file.close()
print(f'[{time.strftime("%H:%M:%S")}] Processing completed in {time.time() - proc_start:.2f}s', flush=True)
print(f'[{time.strftime("%H:%M:%S")}] Close completed in {time.time() - close_start:.2f}s', flush=True)

total_time = time.time() - start_time
print(f'[{time.strftime("%H:%M:%S")}] Total time: {total_time:.2f}s', flush=True)
