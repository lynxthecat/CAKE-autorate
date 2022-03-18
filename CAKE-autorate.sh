#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and ICMP responses

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bash, fping and coreutils-sleep

# Possible performance improvement
export LC_ALL=C
export TZ=UTC

. ./config.sh

update_loads()
{
        read -r cur_rx_bytes < "$rx_bytes_path"
        read -r cur_tx_bytes < "$tx_bytes_path"
        t_cur_bytes=${EPOCHREALTIME/./}

        rx_load=$(( ( (8*10**5*($cur_rx_bytes - $prev_rx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_dl_rate  ))
        tx_load=$(( ( (8*10**5*($cur_tx_bytes - $prev_tx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_ul_rate  ))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes
}

update_baseline()
{
        local RTT=$1
        local RTT_delta=$2
	local RTT_baseline=$3

        local RTT_baseline

        if (( $RTT_delta >= 0 )); then
                RTT_baseline=$(( ( (1000-$alpha_baseline_increase)*$RTT_baseline+$alpha_baseline_increase*$RTT )/1000 ))
        else
                RTT_baseline=$(( ( (1000-$alpha_baseline_decrease)*$RTT_baseline+$alpha_baseline_decrease*$RTT )/1000 ))
        fi

	echo $RTT_baseline
}

get_next_shaper_rate() 
{

    	local cur_rate=$1
	local cur_min_rate=$2
	local cur_base_rate=$3
	local cur_max_rate=$4
	local load_condition=$5
	local t_next_rate=$6
	local -n t_last_bufferbloat=$7
	local -n t_last_decay=$8
    	local -n next_rate=$9

	local cur_rate_decayed_down
 	local cur_rate_decayed_up

	case $load_condition in

 		# in case of supra-threshold OWD spikes decrease the rate providing not inside bufferbloat refractory period
		bufferbloat)
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
        			next_rate=$(( $cur_rate*(1000-$rate_adjust_bufferbloat)/1000 ))
				t_last_bufferbloat=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
           	# ... otherwise determine whether to increase or decrease the rate in dependence on load
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high_load)	
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
                		next_rate=$(($cur_rate*(1000+$rate_adjust_load_high)/1000 ))
			
			else
				next_rate=$cur_rate
			fi
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low_load)
			if (($t_next_rate > ($t_last_decay+(10**3)*$decay_refractory_period) )); then
		
	                	cur_rate_decayed_down=$(($cur_rate*(1000-$rate_adjust_load_low)/1000))
        	        	cur_rate_decayed_up=$(($cur_rate*(1000+$rate_adjust_load_low)/1000))

                		# gently decrease to steady state rate
	                	if (($cur_rate_decayed_down > $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_down
                		# gently increase to steady state rate
	                	elif (($cur_rate_decayed_up < $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_up
                		# steady state has been reached
	               		else
					next_rate=$cur_base_rate
				fi
				t_last_decay=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        if (($next_rate < $cur_min_rate)); then
            next_rate=$cur_min_rate;
        fi

        if (($next_rate > $cur_max_rate)); then
            next_rate=$cur_max_rate;
        fi
}

# Initiliaze variables

cur_dl_rate=$base_dl_rate
cur_ul_rate=$base_ul_rate

last_dl_rate=$cur_dl_rate
last_ul_rate=$cur_ul_rate

read -r prev_rx_bytes < "$tx_bytes_path"
read -r prev_tx_bytes < "$rx_bytes_path"

t_prev_bytes=${EPOCHREALTIME/./}

t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes

delays=( $(printf ' 0%.0s' $(seq $bufferbloat_detection_window)) )

declare -A RTT_baselines
# Initialize RTT_baselines
while read -r reflector _ _ _ _ _ _ result 
do 
	result=(${result//"/"/ }); 
	RTT_baselines[$reflector]=$(printf %.0f\\n "${result[1]}e3")
done <<<$(fping --quiet --period 100 -c 10 ${reflectors[@]} 2>&1)

while true
do
	while read -r timestamp reflector _ seq timeout _ RTT _ _
	do 

		# Skip any timeouts
		[[ $timeout -eq "timed" ]] && continue

		t_start=${EPOCHREALTIME/./}
		# Skip past any ping results older than 500ms (clutch)
		#((($t_start-"${timestamp//[[\[\].]}")>500000)) && echo "WARNING: encountered response from [" $reflector "] that is > 500ms old. Skipping." && continue

		RTT=$(printf %.0f\\n "${RTT}e3")
	
		RTT_delta=$(( $RTT - ${RTT_baselines[$reflector]} ))

		unset 'delays[0]'
	
		if (($RTT_delta > (1000*$delay_thr))); then 
			delays+=(1)
		else 
			delays+=(0)
		fi	

		delays=(${delays[*]})

		#RTT_baselines[$reflector]=$(update_baseline $RTT $RTT_delta RTT_baselines[$reflector])
	
		if (( $RTT_delta >= 0 )); then
			RTT_baselines[$reflector]=$(( ( (1000-$alpha_baseline_increase)*${RTT_baselines[$reflector]}+$alpha_baseline_increase*$RTT )/1000 ))
		else
			RTT_baselines[$reflector]=$(( ( (1000-$alpha_baseline_decrease)*${RTT_baselines[$reflector]}+$alpha_baseline_decrease*$RTT )/1000 ))
		fi

		update_loads

		dl_load_condition="low_load"
		(($rx_load > $high_load_thr)) && dl_load_condition="high_load"

		ul_load_condition="low_load"
		(($tx_load > $high_load_thr)) && ul_load_condition="high_load"
	
		sum_delays=$(IFS=+; echo "$((${delays[*]}))")

		(($sum_delays>$bufferbloat_detection_thr)) && ul_load_condition="bufferbloat" && dl_load_condition="bufferbloat"

		get_next_shaper_rate $cur_dl_rate $min_dl_rate $base_dl_rate $max_dl_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay cur_dl_rate
		get_next_shaper_rate $cur_ul_rate $min_ul_rate $base_ul_rate $max_ul_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay cur_ul_rate

		(($output_processing_stats)) && echo $EPOCHREALTIME $rx_load $tx_load $cur_dl_rate $cur_ul_rate $timestamp $reflector ${RTT_baselines[$reflector]} $RTT $RTT_delta $sum_delays $dl_load_condition $ul_load_condition "${delays[*]}"

       		# fire up tc if there are rates to change
		if (( $cur_dl_rate != $last_dl_rate)); then
       			(($output_cake_changes)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
       			tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
			t_prev_dl_rate_set=${EPOCHREALTIME/./}
		fi
       		if (( $cur_ul_rate != $last_ul_rate )); then
         		(($output_cake_changes)) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
       			tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
			t_prev_ul_rate_set=${EPOCHREALTIME/./}
		fi
		
		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (( $cur_ul_rate == $base_ul_rate && $last_ul_rate == $base_ul_rate && $cur_dl_rate == $base_dl_rate && $last_dl_rate == $base_dl_rate )); then
			((t_sustained_base_rate+=$((${EPOCHREALTIME/./}-$t_end))))
			(($t_sustained_base_rate>(10**6*$sustained_base_rate_sleep_thr))) && break
		else
			# reset timer
			t_sustained_base_rate=0
		fi

		# remember the last rates
       		last_dl_rate=$cur_dl_rate
       		last_ul_rate=$cur_ul_rate

		t_end=${EPOCHREALTIME/./}

	done < <(fping --timestamp --loop --period $reflector_ping_interval --timeout 500 ${reflectors[@]} 2>/dev/null)

	# we broke out of processing loop, so conservatively set hard minimums and wait until there is a load increase again
	cur_dl_rate=$min_dl_rate
        tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
	cur_ul_rate=$min_ul_rate
        tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
	# remember the last rates
	last_ul_rate=$cur_ul_rate
	last_dl_rate=$cur_dl_rate

	# wait until load increases again
	while true
	do
		t_start=${EPOCHREALTIME/./}	
		update_loads
		(($rx_load>$high_load_thr || $tx_load>$high_load_thr)) && break 
		t_end=${EPOCHREALTIME/./}
		sleep $(($t_end-$t_start))"e-6"
	done
done

