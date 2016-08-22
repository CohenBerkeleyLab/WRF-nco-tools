#!/bin/bash
# Script to be executed on the HPC cluster through the
# slurmrun_wrf_output.sh shell script. Will iterate
# through the list of files passed to it and pull out/
# calculate the necessary quantities to use WRF output
# as BEHR a priori
# Josh Laughner <joshlaugh5@gmail.com> 1 Jul 2015

# Retrieve the operational mode from the environmental variable
mode=$WRFPROCMODE

# Where the various NCO scripts are located
scriptdir=$JLL_WRFSCRIPT_DIR
if [[ $scriptdir == '' ]]
then
    echo "Error at $LINENO in read_wrf_output.sh: JLL_WRFSCRIPT_DIR not set"
    exit 1
fi


wrffiles=$(cat $1)
tempoutc="13 14 15 16 17 18 19 20 21 22"

for tempohr in $tempoutc
do
    # Keep a list of the files to concatenate
    catfiles=''
    
    echo "Finding hour $tempohr"
    for file in $wrffiles
    do
        # Get the date from the file names for the save name
        day=${file:11:10}

        # Get the hour of the day (in UTC time) from the file name
        # and write it to our temporary file, we can use this later
        # to select or weight profiles
        hr=${file:22:2}
        if [[ $hr == $tempohr ]]
        then
            echo "        Saving UTC hour..."
        else
            continue
        fi
        ncap2 -O -v -s "utchr[Time]=$hr" $file $file.tmpnc

        # Copy the variables needed to keep track of position & time,
        # plus the species mixing ratios that we're interested in.
        # U and V are temporary for studying the effect of wind on a priori
        # COSALPHA AND SINALPHA are needed to convert the winds from grid
        # relative to earth relative. See http://forum.wrfforum.com/viewtopic.php?f=8&t=3225
        echo "        Copying variables..."
        ncks -A -v 'Times,XLAT,XLONG,no2,PBLH' $file $file.tmpnc

        # Calculate the other quantities we want, like altitude, box height,
        # actual level pressure, number density of air
        echo "       Calcuating additional quantities..."
        ncap2 -A -v -S $scriptdir/calculated_quantities.nco $file $file.tmpnc
        
        # Also calculate the longitudinal weights (var lonweight)
        # these will be used to weight the time average of the 
        # profiles to account for the representativeness of the 
        # profiles
        echo "        Calculating lonweights..."
        ncap2 -A -v -S $scriptdir/lonweight.nco $file $file.tmpnc

        # Append the current .tmpnc file to the list of files to concatenate
        catfiles=$(echo $catfiles $file.tmpnc)
    done
    
    if [[ -z $catfiles ]]
    then
        echo "No files for hr $tempohr"
        continue
    fi

    # WRFPROCMODE is set in the slurmrun script - it's basically the level of averaging
    savename="WRF_TEMPO_${WRFPROCMODE}_${day}-${tempohr}" 
    savenames=$(echo $savenames $savename.hrnc)
    # Concatenate (along time as it's the record dimension)
    echo "Concatenating into $savename.tmpnc"
    ncrcat $catfiles $savename.tmpnc
    # Average over Time. This should either remove it as a dimension
    # (if only one) or ensure that if output is on each half hour
    # that there's only one entry per hour.
    ncwa -a Time $savename.tmpnc $savename.hrnc
done

# Finally concatenate one last time to put all the various hours together
if [[ -z $savenames ]]
then
    echo "No save files created"
    exit 0
fi

if [[ $WRFPROCMODE =~ 'monthly' ]]
then
    day=${day:0:7}
fi
finalname="WRF_TEMPO_${WRFPROCMODE}_${day}"
echo "Combining $savenames"
ncecat -u "hour_index" $savenames $finalname.nc
