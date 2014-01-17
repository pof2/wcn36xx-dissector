-- Copyright (C) 2013 Mikael Kanstrup (mikael.kanstrup@gmail.com)
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

local wcn36xx = Proto("wcn36xx", "wcn36xx HAL dissector")
local f = wcn36xx.fields
local msg_type_strings = {}
local driver_type_strings = {}
local bond_state_strings = {}
local cfg_strings = {}
local offload_type_strings = {}
local sys_mode_strings = {}
local link_state_strings = {}
local filter_type_strings = {}
local filter_protocol_type_strings = {}
local filter_cmp_type_strings = {}

-- Firmware version
local fw_major = 0
local fw_minor = 0
local fw_version = 0
local fw_revision = 0

function wcn36xx.init()
	-- Hook into ethertype parser
	-- Bogus value 0x3660 used together with textpcap dummy header generation
	local udp_table = DissectorTable.get("ethertype")
	local pattern = 0x3660
	udp_table:add(pattern, wcn36xx)
end

function parse_cfg(buffer, pinfo, tree)
	local n = 0
	local id
	local len
	local pad
	local elements
	while buffer:len() > n do
		id = buffer(n, 2):le_uint()
		len = buffer(n + 2, 2):le_uint()
		pad = buffer(n + 4, 2):le_uint()
		local str
		if (cfg_strings[id] ~= nil) then
			str = cfg_strings[id]:lower()
		else
			str = id
		end
		elements = tree:add(wcn36xx, buffer(n, len + 8), str)
		elements:add_le(f.cfg_id, buffer(n, 2)); n = n + 2
		elements:add_le(f.cfg_len, buffer(n, 2)); n = n + 2
		elements:add_le(f.cfg_pad_bytes, buffer(n, 2)); n = n + 2
		elements:add_le(f.cfg_reserve, buffer(n, 2)); n = n + 2
		if (len == 4) then
			-- Value likely a uint32 so parse it like one
			elements:add_le(f.cfg_value, buffer(n, len)); n = n + len
		else
			elements:add(f.cfg_body, buffer(n, len)); n = n + len
		end
		n = n + pad
	end
	return n
end

function wcn36xx.dissector(inbuffer, pinfo, tree)
	local n = 0
	local buffer = inbuffer
	pinfo.cols.protocol = "wcn36xx"
	pinfo.cols.info = ""

	local msg_type = buffer(0, 2):le_uint();
	local cmd_len = buffer(4, 4):le_uint()

	if (buffer:len() <= 46) then
		-- Ethernet frames are 64 (60) bytes minimum. Remove dummy
		-- trailing data if commands are smaller than that.
		buffer = buffer(0, cmd_len)
	end
	if (cmd_len == 0) then
		pinfo.cols.info:append("zero length command!")
		return
	end

	local subtree = tree:add(wcn36xx, buffer(), "wcn36xx HAL protocol data")
	local header = subtree:add(wcn36xx, buffer(n, 8), "header")

	if (buffer:len() <= 46) then
		tree:add(wcn36xx, inbuffer(cmd_len), "Ethernet frame dummy data")
	end

	header:add_le(f.msg_type, buffer(n, 2)); n = n + 2
	header:add_le(f.msg_version, buffer(n, 2)); n = n + 2
	header:add_le(f.len, buffer(n, 4)); n = n +  4

	local msg_type_str
	if msg_type_strings[msg_type] ~= nil then
		msg_type_str = msg_type_strings[msg_type]:lower()
	else
		msg_type_str = msg_type
	end
	pinfo.cols.info:append(msg_type_str)

	-- data
	if buffer:len() > n then
		local params = subtree:add(wcn36xx, buffer(n), msg_type_str)

		if (msg_type == 0) then
			-- start
			params:add_le(f.start_driver_type, buffer(n, 4)); n = n + 4
			local start_len = buffer(n, 4):le_uint()
			params:add_le(f.start_len, buffer(n, 4)); n = n + 4
			while ((buffer:len() > n) and
			       (start_len > (n - 8))) do
				n = n + parse_cfg(buffer(n):tvb(), pinfo, params)
			end
		elseif (msg_type == 4) then
			-- init scan
			params:add_le(f.init_scan_mode, buffer(n, 4)); n = n + 4
			params:add_le(f.init_scan_bssid, buffer(n, 6)); n = n + 6
			params:add(f.init_scan_notify, buffer(n, 1)); n = n + 1
			params:add(f.init_scan_frame_type, buffer(n, 1)); n = n + 1
			params:add(f.init_scan_frame_len, buffer(n, 1)); n = n + 1
			local hdr = params:add(wcn36xx, buffer(n, 24), "msg_mgmt_hdr")
			hdr:add_le(f.hal_mac_frame_ctl, buffer(n, 2)); n = n + 2
			hdr:add(f.hal_mac_mgmt_hdr_duration_lo, buffer(n, 1)); n = n + 1
			hdr:add(f.hal_mac_mgmt_hdr_duration_hi, buffer(n, 1)); n = n + 1
			hdr:add_le(f.hal_mac_mgmt_hdr_da, buffer(n, 6)); n = n + 6
			hdr:add_le(f.hal_mac_mgmt_hdr_sa, buffer(n, 6)); n = n + 6
			hdr:add_le(f.hal_mac_mgmt_hdr_bssid, buffer(n, 6)); n = n + 6
			hdr:add_le(f.hal_mac_mgmt_hdr_seq_ctl, buffer(n, 2)); n = n + 2
			local scan_entry = params:add(wcn36xx, buffer(n, 3), "scan_entry")
			scan_entry:add(f.hal_scan_entry_bss_index, buffer(n, 2)); n = n + 2
			scan_entry:add(f.hal_scan_entry_active_bss_count, buffer(n, 1)); n = n + 1
		elseif ((msg_type == 6) or
			(msg_type == 8)) then
			-- start/end scan
			local channel = buffer(n, 1):uint(); n = n + 1
			pinfo.cols.info:append(", channel "..channel)
			params:add(f.scan_channel, channel)
		elseif (msg_type == 14) then
			-- delete sta
			params:add(f.del_sta_sta_index, buffer(n, 1)); n = n + 1
		elseif (msg_type == 18) then
			-- delete sta
			params:add(f.del_bss_sta_index, buffer(n, 1)); n = n + 1
		elseif (msg_type == 20) then
			-- join
			params:add_le(f.join_bssid, buffer(n, 6)); n = n + 6
			params:add(f.join_channel, buffer(n, 1)); n = n + 1
			params:add_le(f.join_self_sta_mac_addr, buffer(n, 6)); n = n + 6
			params:add(f.join_local_power_constraint, buffer(n, 1)); n = n + 1
			params:add_le(f.join_secondary_channel_offset, buffer(n, 4)); n = n + 4
			params:add_le(f.join_link_state, buffer(n, 4)); n = n + 4
			params:add(f.join_max_tx_power, buffer(n, 1)); n = n + 1
		elseif (msg_type == 38) then
			-- add ba
			params:add(f.add_ba_session_id, buffer(n, 1)); n = n + 1
			params:add(f.add_ba_win_size, buffer(n, 1)); n = n + 1
			if buffer:len() > n then
				params:add(f.add_ba_reorder_on_chip, buffer(n, 1)); n = n + 1
			end
		elseif (msg_type == 42) then
			-- channel switch
			local channel = buffer(n, 1):uint(); n = n + 1
			pinfo.cols.info:append(", channel "..channel)
			params:add(f.ch_switch_channel_number, channel)
			params:add(f.ch_switch_local_power_constraint, buffer(n, 1)); n = n + 1
			params:add_le(f.ch_switch_secondary_channel_offset, buffer(n, 4)); n = n + 4
			params:add(f.ch_switch_tx_mgmt_power, buffer(n, 1)); n = n + 1
			params:add(f.ch_switch_max_tx_power, buffer(n, 1)); n = n + 1
			params:add_le(f.ch_switch_self_sta_mac_addr, buffer(n, 6)); n = n + 6
			params:add_le(f.ch_switch_bssid, buffer(n, 6)); n = n + 6
		elseif (msg_type == 44) then
			-- set link state
			params:add_le(f.set_link_st_bssid, buffer(n, 6)); n = n + 6
			params:add_le(f.set_link_st_state, buffer(n, 4)); n = n + 4
			params:add_le(f.set_link_st_self_mac_addr, buffer(n, 6)); n = n + 6
		elseif (msg_type == 48) then
			-- update cfg
			params:add_le(f.update_cfg_len, buffer(n, 4)); n = n + 4
			while buffer:len() > n do
				n = n + parse_cfg(buffer(n):tvb(), pinfo, params)
			end
		elseif (msg_type == 55) then
			-- download nv
			params:add_le(f.nv_frag_number, buffer(n, 2)); n = n + 2
			params:add_le(f.nv_last_fragment, buffer(n, 2)); n = n + 2
			local size = buffer(n, 4):le_uint()
			params:add_le(f.nv_img_buffer_size, buffer(n, 4)); n = n + 4
			params:add_le(f.nv_buffer, buffer(n, size)); n = n + size
		elseif (msg_type == 57) then
			-- add ba session
			params:add_le(f.add_ba_session_sta_index, buffer(n, 2)); n = n + 2
			params:add_le(f.add_ba_session_mac_addr, buffer(n, 6)); n = n + 6
			params:add(f.add_ba_session_dialog_token, buffer(n, 1)); n = n + 1
			params:add(f.add_ba_session_tid, buffer(n, 1)); n = n + 1
			params:add(f.add_ba_session_policy, buffer(n, 1)); n = n + 1
			params:add_le(f.add_ba_session_buffer_size, buffer(n, 2)); n = n + 2
			params:add_le(f.add_ba_session_timeout, buffer(n, 2)); n = n + 2
			params:add_le(f.add_ba_session_ssn, buffer(n, 2)); n = n + 2
			params:add(f.add_ba_session_direction, buffer(n, 1)); n = n + 1
		elseif (msg_type == 84) then
			-- add beacon filter
			params:add_le(f.beacon_filter_capability_info, buffer(n, 2)); n = n + 2
			params:add_le(f.beacon_filter_capability_mask, buffer(n, 2)); n = n + 2
			params:add_le(f.beacon_filter_beacon_interval, buffer(n, 2)); n = n + 2
			local num = buffer(n, 2):le_uint()
			params:add_le(f.beacon_filter_ie_num, buffer(n, 2)); n = n + 2
			params:add(f.beacon_filter_bss_index, buffer(n, 1)); n = n + 1
			params:add(f.beacon_filter_reserved, buffer(n, 1)); n = n + 1
			local elements
			for i = 1,num do
				elements = params:add(wcn36xx, buffer(n, 6), i)
				elements:add(f.beacon_filter_element_id, buffer(n, 1)); n = n + 1
				elements:add(f.beacon_filter_check_ie_presence, buffer(n, 1)); n = n + 1
				elements:add(f.beacon_filter_n, buffer(n, 1)); n = n + 1
				elements:add(f.beacon_filter_value, buffer(n, 1)); n = n + 1
				elements:add(f.beacon_filter_bitmask, buffer(n, 1)); n = n + 1
				elements:add(f.beacon_filter_ref, buffer(n, 1)); n = n + 1
			end
		elseif (msg_type == 90) then
			-- host offload
			local type = buffer(n, 1):uint()
			params:add(f.host_offload_type, buffer(n, 1)); n = n + 1
			params:add(f.host_offload_enable, buffer(n, 1)); n = n + 1
			if (type == 0) then
				-- arp reply offload
				params:add(f.host_offload_ipv4, buffer(n, 4)); n = n + 16
			elseif (type == 1) then
				-- ipv6 neighbor discovery offload
				params:add(f.host_offload_ipv6, buffer(n, 16)); n = n + 16
			else
				-- ipv6 ns offload
				params:add(f.ns_offload_src_ipv6, buffer(n, 16)); n = n + 16
				params:add(f.ns_offload_self_ipv6, buffer(n, 16)); n = n + 16
				params:add(f.ns_offload_target_ipv6, buffer(n, 16)); n = n + 16
				params:add(f.ns_offload_target_ipv6_2, buffer(n, 16)); n = n + 16
				params:add_le(f.ns_offload_self_addr, buffer(n, 6)); n = n + 6
				params:add(f.ns_offload_valid, buffer(n, 1)); n = n + 1
				params:add(f.ns_offload_reserved2, buffer(n, 1)); n = n + 1
				params:add(f.ns_offload_bss_index, buffer(n, 1)); n = n + 1
				params:add_le(f.ns_offload_slot_index, buffer(n, 4)); n = n + 4
			end
		elseif (msg_type == 91) then
			-- set rssi threshold
			params:add(f.set_rssi_threshold_t1, buffer(n, 1)); n = n + 1
			params:add(f.set_rssi_threshold_t2, buffer(n, 1)); n = n + 1
			params:add(f.set_rssi_threshold_t3, buffer(n, 1)); n = n + 1
			params:add(f.set_rssi_threshold_t1pos, buffer(n, 1):bitfield(7));
			params:add(f.set_rssi_threshold_t1neg, buffer(n, 1):bitfield(6));
			params:add(f.set_rssi_threshold_t2pos, buffer(n, 1):bitfield(5));
			params:add(f.set_rssi_threshold_t2neg, buffer(n, 1):bitfield(4));
			params:add(f.set_rssi_threshold_t3pos, buffer(n, 1):bitfield(3));
			params:add(f.set_rssi_threshold_t3neg, buffer(n, 1):bitfield(2));
			n = n + 1
		elseif (msg_type == 125) then
			-- add sta self
			params:add_le(f.add_sta_self_addr, buffer(n, 6)); n = n + 6
			params:add_le(f.add_sta_self_status, buffer(n, 4)); n = n + 4
		elseif (msg_type == 151) then
			-- update scan param
			params:add(f.scan_dot11d_enabled, buffer(n, 1)); n = n + 1
			params:add(f.scan_dot11d_resolved, buffer(n, 1)); n = n + 1
			local channel_count = buffer(n, 1):uint()
			params:add(f.scan_channel_count, buffer(n, 1)); n = n + 1
			local elements = params:add(wcn36xx, buffer(n, channel_count), "channels")
			local index = n
			for i = 1,channel_count do
				elements:add(f.scan_channels_i, buffer(index, 1)); index = index + 1
			end
			n = n + 60
			params:add_le(f.scan_active_min_ch_time, buffer(n, 2)); n = n + 2
			params:add_le(f.scan_active_max_ch_time, buffer(n, 2)); n = n + 2
			params:add_le(f.scan_passive_min_ch_time, buffer(n, 2)); n = n + 2
			params:add_le(f.scan_passive_max_ch_time, buffer(n, 2)); n = n + 2
			params:add_le(f.scan_phy_chan_bond_state, buffer(n, 4)); n = n + 4
		elseif (msg_type == 157) then
			-- 8023 multicast list
			params:add(f.multicast_list_data_offset, buffer(n, 1)); n = n + 1
			local addr_count = buffer(n, 4):le_uint()
			params:add_le(f.multicast_list_addr_count, buffer(n, 4)); n = n + 4
			for i = 1,addr_count do
				params:add_le(f.multicast_list_address, buffer(n, 6)); n = n + 6
			end
			params:add(f.multicast_list_bss_index, buffer(n, 1)); n = n + 1
		elseif (msg_type == 159) then
			-- rcv packet filter
			params:add(f.rcv_packet_filter_id, buffer(n, 1)); n = n + 1
			params:add(f.rcv_packet_filter_type, buffer(n, 1)); n = n + 1
			local count = buffer(n, 1):uint()
			params:add(f.rcv_packet_filter_params_count, buffer(n, 1)); n = n + 1
			params:add_le(f.rcv_packet_filter_coalesce_time, buffer(n, 4)); n = n + 4
			params:add(f.rcv_packet_filter_bssid, buffer(n, 1)); n = n + 1
			for i = 1,count do
				local fltparams = subtree:add(wcn36xx, buffer(n, 22), i)
				fltparams:add(f.rcv_packet_filter_param_protocol_layer, buffer(n, 1)); n = n + 1
				fltparams:add(f.rcv_packet_filter_param_cmp_flag, buffer(n, 1)); n = n + 1
				fltparams:add_le(f.rcv_packet_filter_param_data_length, buffer(n, 2)); n = n + 2
				fltparams:add(f.rcv_packet_filter_param_data_offset, buffer(n, 1)); n = n + 1
				fltparams:add(f.rcv_packet_filter_param_reserved, buffer(n, 1)); n = n + 1
				fltparams:add(f.rcv_packet_filter_param_compare_data, buffer(n, 8)); n = n + 8
				fltparams:add(f.rcv_packet_filter_param_data_mask, buffer(n, 8)); n = n + 8
			end
		elseif (msg_type == 166) then
			-- set power params
			params:add_le(f.set_power_params_ignore_dtim, buffer(n, 4)); n = n + 4
			params:add_le(f.set_power_params_dtim_period, buffer(n, 4)); n = n + 4
			params:add_le(f.set_power_params_listen_interval, buffer(n, 4)); n = n + 4
			params:add_le(f.set_power_params_bcast_mcast_filter, buffer(n, 4)); n = n + 4
			params:add_le(f.set_power_params_enable_bet, buffer(n, 4)); n = n + 4
			params:add_le(f.set_power_params_bet_interval, buffer(n, 4)); n = n + 4
		elseif ((msg_type < 191) and
			(string.find(msg_type_strings[msg_type], "RSP") ~= nil)) then
			-- parse responses
			local status
			if (msg_type == 1) then
				-- start rsp
				status = buffer(n, 2):le_uint()
				params:add_le(f.start_rsp_status, buffer(n, 2)); n = n + 2
				-- jump to fw version
				n = n + 2
				fw_revision = buffer(n, 1)
				fw_version = buffer(n + 1, 1)
				fw_minor = buffer(n + 2, 1)
				fw_major = buffer(n + 3, 1)
				params:add(f.start_rsp_fw_revision, buffer(n, 1)); n = n + 1
				params:add(f.start_rsp_fw_version, buffer(n, 1)); n = n + 1
				params:add(f.start_rsp_fw_minor, buffer(n, 1)); n = n + 1
				params:add(f.start_rsp_fw_major, buffer(n, 1)); n = n + 1
			elseif (msg_type == 60) then
				-- trigger ba
				params:add_le(f.trigger_ba_rsp_bssid, buffer(n, 6)); n = n + 6
				status = buffer(n, 4):le_uint()
				params:add_le(f.rsp_status, buffer(n, 4)); n = n + 4
				params:add_le(f.trigger_ba_rsp_candidate_cnt, buffer(n, 2)); n = n + 2
			elseif (msg_type == 75) then
				-- tl flush ac
				params:add(f.tl_flush_ac_sta_id, buffer(n, 1)); n = n + 1
				params:add(f.tl_flush_ac_tid, buffer(n, 1)); n = n + 1
				status = buffer(n, 4):le_uint()
				params:add_le(f.rsp_status, buffer(n, 4)); n = n + 4
			elseif (msg_type == 116) then
				-- set max tx power
				params:add(f.set_max_tx_power_rsp_power, buffer(n, 1)); n = n + 1
				status = buffer(n, 4):le_uint()
				params:add_le(f.rsp_status, buffer(n, 4)); n = n + 4
			elseif (msg_type == 124) then
				-- start oem data
				params:add(f.start_oem_data_data, buffer(n))
				status = 0
			elseif (msg_type == 176) then
				status = 0
			elseif (msg_type == 140) then
				-- enable radar
				params:add_le(f.enable_radar_rsp_bssid, buffer(n, 6)); n = n + 6
				status = buffer(n, 4):le_uint()
				params:add_le(f.rsp_status, buffer(n, 4)); n = n + 4
			else
				-- all others
				status = buffer(n, 4):le_uint()
				params:add_le(f.rsp_status, buffer(n, 4)); n = n + 4
			end

			if (status == 0) then
				pinfo.cols.info:append(" success")
			else
				pinfo.cols.info:append(" failure "..status);
			end
			if (msg_type == 1) then
				pinfo.cols.info:append(", fw_version "..fw_major.."."..fw_minor.."."..fw_version.."."..fw_revision)
			end
		else
			-- unknown command
		end

		-- add data not parsed above
		if (buffer:len() > n) then
			params:add(f.data, buffer(n))
		end
	end
end

function get_fw_version()
	if (fw_major == 0) then
		version = 0
	elseif (not (fw_major == 1 and
		     fw_minor == 4 and
		     fw_version == 1 and
		     fw_revision == 2)) then
		version = 1
	else
		version = 2
	end
	return version
end
-- Lookup strings
msg_type_strings[0] = "START_REQ"
msg_type_strings[1] = "START_RSP"
msg_type_strings[2] = "STOP_REQ"
msg_type_strings[3] = "STOP_RSP"
msg_type_strings[4] = "INIT_SCAN_REQ"
msg_type_strings[5] = "INIT_SCAN_RSP"
msg_type_strings[6] = "START_SCAN_REQ"
msg_type_strings[7] = "START_SCAN_RSP"
msg_type_strings[8] = "END_SCAN_REQ"
msg_type_strings[9] = "END_SCAN_RSP"
msg_type_strings[10] = "FINISH_SCAN_REQ"
msg_type_strings[11] = "FINISH_SCAN_RSP"
msg_type_strings[12] = "CONFIG_STA_REQ"
msg_type_strings[13] = "CONFIG_STA_RSP"
msg_type_strings[14] = "DELETE_STA_REQ"
msg_type_strings[15] = "DELETE_STA_RSP"
msg_type_strings[16] = "CONFIG_BSS_REQ"
msg_type_strings[17] = "CONFIG_BSS_RSP"
msg_type_strings[18] = "DELETE_BSS_REQ"
msg_type_strings[19] = "DELETE_BSS_RSP"
msg_type_strings[20] = "JOIN_REQ"
msg_type_strings[21] = "JOIN_RSP"
msg_type_strings[22] = "POST_ASSOC_REQ"
msg_type_strings[23] = "POST_ASSOC_RSP"
msg_type_strings[24] = "SET_BSSKEY_REQ"
msg_type_strings[25] = "SET_BSSKEY_RSP"
msg_type_strings[26] = "SET_STAKEY_REQ"
msg_type_strings[27] = "SET_STAKEY_RSP"
msg_type_strings[28] = "RMV_BSSKEY_REQ"
msg_type_strings[29] = "RMV_BSSKEY_RSP"
msg_type_strings[30] = "RMV_STAKEY_REQ"
msg_type_strings[31] = "RMV_STAKEY_RSP"
msg_type_strings[32] = "ADD_TS_REQ"
msg_type_strings[33] = "ADD_TS_RSP"
msg_type_strings[34] = "DEL_TS_REQ"
msg_type_strings[35] = "DEL_TS_RSP"
msg_type_strings[36] = "UPD_EDCA_PARAMS_REQ"
msg_type_strings[37] = "UPD_EDCA_PARAMS_RSO"
msg_type_strings[38] = "ADD_BA_REQ"
msg_type_strings[39] = "ADD_BA_RSP"
msg_type_strings[40] = "DEL_BA_REQ"
msg_type_strings[41] = "DEL_BA_RSP"
msg_type_strings[42] = "CH_SWITCH_REQ"
msg_type_strings[43] = "CH_SWITCH_RSP"
msg_type_strings[44] = "SET_LINK_ST_REQ"
msg_type_strings[45] = "SET_LINK_ST_RSP"
msg_type_strings[46] = "GET_STATS_REQ"
msg_type_strings[47] = "GET_STATS_RSP"
msg_type_strings[48] = "UPDATE_CFG_REQ"
msg_type_strings[49] = "UPDATE_CFG_RSP"
msg_type_strings[50] = "MISSED_BEACON_IND"
msg_type_strings[51] = "UNKNOWN_ADDR2_FRAME_RX_IND"
msg_type_strings[52] = "MIC_FAILURE_IND"
msg_type_strings[53] = "FATAL_ERROR_IND"
msg_type_strings[54] = "SET_KEYDONE_MSG"
msg_type_strings[55] = "DOWNLOAD_NV_REQ"
msg_type_strings[56] = "DOWNLOAD_NV_RSP"
msg_type_strings[57] = "ADD_BA_SESSION_REQ"
msg_type_strings[58] = "ADD_BA_SESSION_RSP"
msg_type_strings[59] = "TRIGGER_BA_REQ"
msg_type_strings[60] = "TRIGGER_BA_RSP"
msg_type_strings[61] = "UPDATE_BEACON_REQ"
msg_type_strings[62] = "UPDATE_BEACON_RSP"
msg_type_strings[63] = "SEND_BEACON_REQ"
msg_type_strings[64] = "SEND_BEACON_RSP"
msg_type_strings[65] = "SET_BCASTKEY_REQ"
msg_type_strings[66] = "SET_BCASTKEY_RSP"
msg_type_strings[67] = "DELETE_STA_CONTEXT_IND"
msg_type_strings[68] = "UPDATE_PROBE_RSP_TEMPLATE_REQ"
msg_type_strings[69] = "UPDATE_PROBE_RSP_TEMPLATE_RSP"
msg_type_strings[70] = "PROCESS_PTT_REQ"
msg_type_strings[71] = "PROCESS_PTT_RSP"
msg_type_strings[72] = "SIGNAL_BTAMP_EVENT_REQ"
msg_type_strings[73] = "SIGNAL_BTAMP_EVENT_RSP"
msg_type_strings[74] = "TL_HAL_FLUSH_AC_REQ"
msg_type_strings[75] = "TL_HAL_FLUSH_AC_RSP"
msg_type_strings[76] = "ENTER_IMPS_REQ"
msg_type_strings[77] = "EXIT_IMPS_REQ"
msg_type_strings[78] = "ENTER_BMPS_REQ"
msg_type_strings[79] = "EXIT_BMPS_REQ"
msg_type_strings[80] = "ENTER_UAPSD_REQ"
msg_type_strings[81] = "EXIT_UAPSD_REQ"
msg_type_strings[82] = "UPDATE_UAPSD_PARAM_REQ"
msg_type_strings[83] = "CONFIGURE_RXP_FILTER_REQ"
msg_type_strings[84] = "ADD_BCN_FILTER_REQ"
msg_type_strings[85] = "REM_BCN_FILTER_REQ"
msg_type_strings[86] = "ADD_WOWL_BCAST_PTRN"
msg_type_strings[87] = "DEL_WOWL_BCAST_PTRN"
msg_type_strings[88] = "ENTER_WOWL_REQ"
msg_type_strings[89] = "EXIT_WOWL_REQ"
msg_type_strings[90] = "HOST_OFFLOAD_REQ"
msg_type_strings[91] = "SET_RSSI_THRESH_REQ"
msg_type_strings[92] = "GET_RSSI_REQ"
msg_type_strings[93] = "SET_UAPSD_AC_PARAMS_REQ"
msg_type_strings[94] = "CONFIGURE_APPS_CPU_WAKEUP_STATE_REQ"
msg_type_strings[95] = "ENTER_IMPS_RSP"
msg_type_strings[96] = "EXIT_IMPS_RSP"
msg_type_strings[97] = "ENTER_BMPS_RSP"
msg_type_strings[98] = "EXIT_BMPS_RSP"
msg_type_strings[99] = "ENTER_UAPSD_RSP"
msg_type_strings[100] = "EXIT_UAPSD_RSP"
msg_type_strings[101] = "SET_UAPSD_AC_PARAMS_RSP"
msg_type_strings[102] = "UPDATE_UAPSD_PARAM_RSP"
msg_type_strings[103] = "CONFIGURE_RXP_FILTER_RSP"
msg_type_strings[104] = "ADD_BCN_FILTER_RSP"
msg_type_strings[105] = "REM_BCN_FILTER_RSP"
msg_type_strings[106] = "SET_RSSI_THRESH_RSP"
msg_type_strings[107] = "HOST_OFFLOAD_RSP"
msg_type_strings[108] = "ADD_WOWL_BCAST_PTRN_RSP"
msg_type_strings[109] = "DEL_WOWL_BCAST_PTRN_RSP"
msg_type_strings[110] = "ENTER_WOWL_RSP"
msg_type_strings[111] = "EXIT_WOWL_RSP"
msg_type_strings[112] = "RSSI_NOTIFICATION_IND"
msg_type_strings[113] = "GET_RSSI_RSP"
msg_type_strings[114] = "CONFIGURE_APPS_CPU_WAKEUP_STATE_RSP"
msg_type_strings[115] = "SET_MAX_TX_POWER_REQ"
msg_type_strings[116] = "SET_MAX_TX_POWER_RSP"
msg_type_strings[117] = "AGGR_ADD_TS_REQ"
msg_type_strings[118] = "AGGR_ADD_TS_RSP"
msg_type_strings[119] = "SET_P2P_GONOA_REQ"
msg_type_strings[120] = "SET_P2P_GONOA_RSP"
msg_type_strings[121] = "DUMP_COMMAND_REQ"
msg_type_strings[122] = "DUMP_COMMAND_RSP"
msg_type_strings[123] = "START_OEM_DATA_REQ"
msg_type_strings[124] = "START_OEM_DATA_RSP"
msg_type_strings[125] = "ADD_STA_SELF_REQ"
msg_type_strings[126] = "ADD_STA_SELF_RSP"
msg_type_strings[127] = "DEL_STA_SELF_REQ"
msg_type_strings[128] = "DEL_STA_SELF_RSP"
msg_type_strings[129] = "COEX_IND"
msg_type_strings[130] = "OTA_TX_COMPL_IND"
msg_type_strings[131] = "HOST_SUSPEND_IND"
msg_type_strings[132] = "HOST_RESUME_REQ"
msg_type_strings[133] = "HOST_RESUME_RSP"
msg_type_strings[134] = "SET_TX_POWER_REQ"
msg_type_strings[135] = "SET_TX_POWER_RSP"
msg_type_strings[136] = "GET_TX_POWER_REQ"
msg_type_strings[137] = "GET_TX_POWER_RSP"
msg_type_strings[138] = "P2P_NOA_ATTR_IND"
msg_type_strings[139] = "ENABLE_RADAR_DETECT_REQ"
msg_type_strings[140] = "ENABLE_RADAR_DETECT_RSP"
msg_type_strings[141] = "GET_TPC_REPORT_REQ"
msg_type_strings[142] = "GET_TPC_REPORT_RSP"
msg_type_strings[143] = "RADAR_DETECT_IND"
msg_type_strings[144] = "RADAR_DETECT_INTR_IND"
msg_type_strings[145] = "KEEP_ALIVE_REQ"
msg_type_strings[146] = "KEEP_ALIVE_RSP"
msg_type_strings[147] = "SET_PREF_NETWORK_REQ"
msg_type_strings[148] = "SET_PREF_NETWORK_RSP"
msg_type_strings[149] = "SET_RSSI_FILTER_REQ"
msg_type_strings[150] = "SET_RSSI_FILTER_RSP"
msg_type_strings[151] = "UPDATE_SCAN_PARAM_REQ"
msg_type_strings[152] = "UPDATE_SCAN_PARAM_RSP"
msg_type_strings[153] = "PREF_NETW_FOUND_IND"
msg_type_strings[154] = "SET_TX_PER_TRACKING_REQ"
msg_type_strings[155] = "SET_TX_PER_TRACKING_RSP"
msg_type_strings[156] = "TX_PER_HIT_IND"
msg_type_strings[157] = "8023_MULTICAST_LIST_REQ"
msg_type_strings[158] = "8023_MULTICAST_LIST_RSP"
msg_type_strings[159] = "SET_PACKET_FILTER_REQ"
msg_type_strings[160] = "SET_PACKET_FILTER_RSP"
msg_type_strings[161] = "PACKET_FILTER_MATCH_COUNT_REQ"
msg_type_strings[162] = "PACKET_FILTER_MATCH_COUNT_RSP"
msg_type_strings[163] = "CLEAR_PACKET_FILTER_REQ"
msg_type_strings[164] = "CLEAR_PACKET_FILTER_RSP"
msg_type_strings[165] = "INIT_SCAN_CON_REQ"
msg_type_strings[166] = "SET_POWER_PARAMS_REQ"
msg_type_strings[167] = "SET_POWER_PARAMS_RSP"
msg_type_strings[168] = "TSM_STATS_REQ"
msg_type_strings[169] = "TSM_STATS_RSP"
msg_type_strings[170] = "WAKE_REASON_IND"
msg_type_strings[171] = "GTK_OFFLOAD_REQ"
msg_type_strings[172] = "GTK_OFFLOAD_RSP"
msg_type_strings[173] = "GTK_OFFLOAD_GETINFO_REQ"
msg_type_strings[174] = "GTK_OFFLOAD_GETINFO_RSP"
msg_type_strings[175] = "FEATURE_CAPS_EXCHANGE_REQ"
msg_type_strings[176] = "FEATURE_CAPS_EXCHANGE_RSP"
msg_type_strings[177] = "EXCLUDE_UNENCRYPTED_IND"
msg_type_strings[178] = "SET_THERMAL_MITIGATION_REQ"
msg_type_strings[179] = "SET_THERMAL_MITIGATION_RSP"
msg_type_strings[180] = "undefined"
msg_type_strings[181] = "undefined"
msg_type_strings[182] = "UPDATE_VHT_OP_MODE_REQ"
msg_type_strings[183] = "UPDATE_VHT_OP_MODE_RSP"
msg_type_strings[184] = "P2P_NOA_START_IND"
msg_type_strings[185] = "GET_ROAM_RSSI_REQ"
msg_type_strings[186] = "GET_ROAM_RSSI_RSP"
msg_type_strings[187] = "CLASS_B_STATS_IND"
msg_type_strings[188] = "DEL_BA_IND"
msg_type_strings[189] = "DHCP_START_IND"
msg_type_strings[190] = "DHCP_STOP_IND"

msg_type_strings[191] = "ROAM_SCAN_OFFLOAD_REQ"
msg_type_strings[192] = "ROAM_SCAN_OFFLOAD_RSP"
msg_type_strings[193] = "WIFI_PROXIMITY_REQ"
msg_type_strings[194] = "WIFI_PROXIMITY_RSP"
msg_type_strings[195] = "START_SPECULATIVE_PS_POLLS_REQ"
msg_type_strings[196] = "START_SPECULATIVE_PS_POLLS_RSP"
msg_type_strings[197] = "STOP_SPECULATIVE_PS_POLLS_IND"

msg_type_strings[198] = "TDLS_LINK_ESTABLISHED_REQ"
msg_type_strings[199] = "TDLS_LINK_ESTABLISHED_RSP"
msg_type_strings[200] = "TDLS_LINK_TEARDOWN_REQ"
msg_type_strings[201] = "TDLS_LINK_TEARDOWN_RSP"
msg_type_strings[202] = "TDLS_IND"
msg_type_strings[203] = "IBSS_PEER_INACTIVITY_IND"

msg_type_strings[211] = "LPHB_CFG_REQ "
msg_type_strings[212] = "LPHB_CFG_RSP"
msg_type_strings[213] = "LPHB_IND"
msg_type_strings[214] = "ADD_PERIODIC_TX_PTRN_IND"
msg_type_strings[215] = "DEL_PERIODIC_TX_PTRN_IND"
msg_type_strings[216] = "PERIODIC_TX_PTRN_FW_IND"

driver_type_strings[0] = "production"
driver_type_strings[1] = "mfg"
driver_type_strings[2] = "dvt"

bond_state_strings[0] = "SINGLE_CHANNEL_CENTERED"
bond_state_strings[1] = "DOUBLE_CHANNEL_LOW_PRIMARY"
bond_state_strings[2] = "DOUBLE_CHANNEL_CENTERED"
bond_state_strings[3] = "DOUBLE_CHANNEL_HIGH_PRIMARY"
bond_state_strings[4] = "QUADRUPLE_CHANNEL_20MHZ_LOW_40MHZ_CENTERED"
bond_state_strings[5] = "QUADRUPLE_CHANNEL_20MHZ_CENTERED_40MHZ_CENTERED"
bond_state_strings[6] = "QUADRUPLE_CHANNEL_20MHZ_HIGH_40MHZ_CENTERED"
bond_state_strings[7] = "QUADRUPLE_CHANNEL_20MHZ_LOW_40MHZ_LOW"
bond_state_strings[8] = "QUADRUPLE_CHANNEL_20MHZ_HIGH_40MHZ_LOW"
bond_state_strings[9] = "QUADRUPLE_CHANNEL_20MHZ_LOW_40MHZ_HIGH "
bond_state_strings[10] = "QUADRUPLE_CHANNEL_20MHZ_HIGH_40MHZ_HIGH"

cfg_strings[0] = "STA_ID"
cfg_strings[1] = "CURRENT_TX_ANTENNA"
cfg_strings[2] = "CURRENT_RX_ANTENNA"
cfg_strings[3] = "LOW_GAIN_OVERRIDE"
cfg_strings[4] = "POWER_STATE_PER_CHAIN"
cfg_strings[5] = "CAL_PERIOD"
cfg_strings[6] = "CAL_CONTROL"
cfg_strings[7] = "PROXIMITY"
cfg_strings[8] = "NETWORK_DENSITY"
cfg_strings[9] = "MAX_MEDIUM_TIME"
cfg_strings[10] = "MAX_MPDUS_IN_AMPDU"
cfg_strings[11] = "RTS_THRESHOLD"
cfg_strings[12] = "SHORT_RETRY_LIMIT"
cfg_strings[13] = "LONG_RETRY_LIMIT"
cfg_strings[14] = "FRAGMENTATION_THRESHOLD"
cfg_strings[15] = "DYNAMIC_THRESHOLD_ZERO"
cfg_strings[16] = "DYNAMIC_THRESHOLD_ONE"
cfg_strings[17] = "DYNAMIC_THRESHOLD_TWO"
cfg_strings[18] = "FIXED_RATE"
cfg_strings[19] = "RETRYRATE_POLICY"
cfg_strings[20] = "RETRYRATE_SECONDARY"
cfg_strings[21] = "RETRYRATE_TERTIARY"
cfg_strings[22] = "FORCE_POLICY_PROTECTION"
cfg_strings[23] = "FIXED_RATE_MULTICAST_24GHZ"
cfg_strings[24] = "FIXED_RATE_MULTICAST_5GHZ"
cfg_strings[25] = "DEFAULT_RATE_INDEX_24GHZ"
cfg_strings[26] = "DEFAULT_RATE_INDEX_5GHZ"
cfg_strings[27] = "MAX_BA_SESSIONS"
cfg_strings[28] = "PS_DATA_INACTIVITY_TIMEOUT"
cfg_strings[29] = "PS_ENABLE_BCN_FILTER"
cfg_strings[30] = "PS_ENABLE_RSSI_MONITOR"
cfg_strings[31] = "NUM_BEACON_PER_RSSI_AVERAGE"
cfg_strings[32] = "STATS_PERIOD"
cfg_strings[33] = "CFP_MAX_DURATION"
cfg_strings[34] = "FRAME_TRANS_ENABLED"
cfg_strings[35] = "DTIM_PERIOD"
cfg_strings[36] = "EDCA_WMM_ACBK"
cfg_strings[37] = "EDCA_WMM_ACBE"
cfg_strings[38] = "EDCA_WMM_ACVO"
cfg_strings[39] = "EDCA_WMM_ACVI"
cfg_strings[40] = "BA_THRESHOLD_HIGH"
cfg_strings[41] = "MAX_BA_BUFFERS"
cfg_strings[42] = "RPE_POLLING_THRESHOLD"
cfg_strings[43] = "RPE_AGING_THRESHOLD_FOR_AC0_REG"
cfg_strings[44] = "RPE_AGING_THRESHOLD_FOR_AC1_REG"
cfg_strings[45] = "RPE_AGING_THRESHOLD_FOR_AC2_REG"
cfg_strings[46] = "RPE_AGING_THRESHOLD_FOR_AC3_REG"
cfg_strings[47] = "NO_OF_ONCHIP_REORDER_SESSIONS"
cfg_strings[48] = "PS_LISTEN_INTERVAL"
cfg_strings[49] = "PS_HEART_BEAT_THRESHOLD"
cfg_strings[50] = "PS_NTH_BEACON_FILTER"
cfg_strings[51] = "PS_MAX_PS_POLL"
cfg_strings[52] = "PS_MIN_RSSI_THRESHOLD"
cfg_strings[53] = "PS_RSSI_FILTER_PERIOD"
cfg_strings[54] = "PS_BROADCAST_FRAME_FILTER_ENABLE"
cfg_strings[55] = "PS_IGNORE_DTIM"
cfg_strings[56] = "PS_ENABLE_BCN_EARLY_TERM"
cfg_strings[57] = "DYNAMIC_PS_POLL_VALUE"
cfg_strings[58] = "PS_NULLDATA_AP_RESP_TIMEOUT"
cfg_strings[59] = "TELE_BCN_WAKEUP_EN"
cfg_strings[60] = "TELE_BCN_TRANS_LI"
cfg_strings[61] = "TELE_BCN_TRANS_LI_IDLE_BCNS"
cfg_strings[62] = "TELE_BCN_MAX_LI"
cfg_strings[63] = "TELE_BCN_MAX_LI_IDLE_BCNS"
cfg_strings[64] = "TX_PWR_CTRL_ENABLE"
cfg_strings[65] = "VALID_RADAR_CHANNEL_LIST"
cfg_strings[66] = "TX_POWER_24_20"
cfg_strings[67] = "TX_POWER_24_40"
cfg_strings[68] = "TX_POWER_50_20"
cfg_strings[69] = "TX_POWER_50_40"
cfg_strings[70] = "MCAST_BCAST_FILTER_SETTING"
cfg_strings[71] = "BCN_EARLY_TERM_WAKEUP_INTERVAL"
cfg_strings[72] = "MAX_TX_POWER_2_4"
cfg_strings[73] = "MAX_TX_POWER_5"
cfg_strings[74] = "INFRA_STA_KEEP_ALIVE_PERIOD"
cfg_strings[75] = "ENABLE_CLOSE_LOOP"
cfg_strings[76] = "BTC_EXECUTION_MODE"
cfg_strings[77] = "BTC_DHCP_BT_SLOTS_TO_BLOCK"
cfg_strings[78] = "BTC_A2DP_DHCP_BT_SUB_INTERVALS"
cfg_strings[79] = "PS_TX_INACTIVITY_TIMEOUT"
cfg_strings[80] = "WCNSS_API_VERSION"
cfg_strings[81] = "AP_KEEPALIVE_TIMEOUT"
cfg_strings[82] = "GO_KEEPALIVE_TIMEOUT"
cfg_strings[83] = "ENABLE_MC_ADDR_LIST"
cfg_strings[84] = "BTC_STATIC_LEN_INQ_BT"
cfg_strings[85] = "BTC_STATIC_LEN_PAGE_BT"
cfg_strings[86] = "BTC_STATIC_LEN_CONN_BT"
cfg_strings[87] = "BTC_STATIC_LEN_LE_BT"
cfg_strings[88] = "BTC_STATIC_LEN_INQ_WLAN"
cfg_strings[89] = "BTC_STATIC_LEN_PAGE_WLAN"
cfg_strings[90] = "BTC_STATIC_LEN_CONN_WLAN"
cfg_strings[91] = "BTC_STATIC_LEN_LE_WLAN"
cfg_strings[92] = "BTC_DYN_MAX_LEN_BT"
cfg_strings[93] = "BTC_DYN_MAX_LEN_WLAN"
cfg_strings[94] = "BTC_MAX_SCO_BLOCK_PERC"
cfg_strings[95] = "BTC_DHCP_PROT_ON_A2DP"
cfg_strings[96] = "BTC_DHCP_PROT_ON_SCO"
cfg_strings[97] = "ENABLE_UNICAST_FILTER"
cfg_strings[98] = "MAX_ASSOC_LIMIT"
cfg_strings[99] = "ENABLE_LPWR_IMG_TRANSITION"
cfg_strings[100] = "ENABLE_MCC_ADAPTIVE_SCHEDULER"
cfg_strings[101] = "ENABLE_DETECT_PS_SUPPORT"
cfg_strings[102] = "AP_LINK_MONITOR_TIMEOUT"
cfg_strings[103] = "BTC_DWELL_TIME_MULTIPLIER"
cfg_strings[103] = "BTC_DWELL_TIME_MULTIPLIER"
cfg_strings[104] = "ENABLE_TDLS_OXYGEN_MODE"
cfg_strings[105] = "ENABLE_NAT_KEEP_ALIVE_FILTER"
cfg_strings[106] = "ENABLE_SAP_OBSS_PROT"
cfg_strings[107] = "PSPOLL_DATA_RECEP_TIMEOUT"
cfg_strings[108] = "TDLS_PUAPSD_BUFFER_STA_CAPABLE"
cfg_strings[109] = "TDLS_PUAPSD_MASK"
cfg_strings[110] = "TDLS_PUAPSD_INACTIVITY_TIME"
cfg_strings[111] = "TDLS_PUAPSD_RX_FRAME_THRESHOLD_IN_SP"
cfg_strings[112] = "ANTENNA_DIVERSITY"
cfg_strings[113] = "ATH_DISABLE"
cfg_strings[114] = "FLEXCONNECT_POWER_FACTOR"
cfg_strings[115] = "ENABLE_ADAPTIVE_RX_DRAIN_FEATURE"
cfg_strings[116] = "GO_LINK_MONITOR_TIMEOUT"

offload_type_strings[0] = "IPV4_ARP_REPLY_OFFLOAD"
offload_type_strings[1] = "IPV6_NEIGHBOR_DISCOVERY_OFFLOAD"
offload_type_strings[2] = "IPV6_NS_OFFLOAD"

sys_mode_strings[0] = "NORMAL"
sys_mode_strings[1] = "LEARN"
sys_mode_strings[2] = "SCAN"
sys_mode_strings[3] = "PROMISC"
sys_mode_strings[4] = "SUSPEND_LINK"
sys_mode_strings[5] = "ROAM_SCAN"
sys_mode_strings[6] = "ROAM_SUSPEND_LINK"

link_state_strings[0] = "IDLE"
link_state_strings[1] = "PREASSOC"
link_state_strings[2] = "POSTASSOC"
link_state_strings[3] = "AP"
link_state_strings[4] = "IBSS"
link_state_strings[5] = "BTAMP_PREASSOC"
link_state_strings[6] = "BTAMP_POSTASSOC"
link_state_strings[7] = "LINK_BTAMP_AP"
link_state_strings[8] = "BTAMP_STA"
link_state_strings[9] = "LEARN"
link_state_strings[10] = "SCAN"
link_state_strings[11] = "FINISH_SCAN"
link_state_strings[12] = "INIT_CAL"
link_state_strings[13] = "FINISH_CAL"
link_state_strings[14] = "LISTEN"

filter_type_strings[0] = "INVALID"
filter_type_strings[1] = "FILTER_PKT"
filter_type_strings[2] = "BUFFER_PKT"

filter_protocol_type_strings[0] = "INVALID"
filter_protocol_type_strings[1] = "MAC"
filter_protocol_type_strings[2] = "ARP"
filter_protocol_type_strings[3] = "IPV4"
filter_protocol_type_strings[4] = "IPV6"
filter_protocol_type_strings[5] = "UDP"

filter_cmp_type_strings[0] = "INVALID"
filter_cmp_type_strings[1] = "EQUAL"
filter_cmp_type_strings[2] = "MASK_EQUAL"
filter_cmp_type_strings[3] = "NOT_EQUAL"

-- Protocol fields
f.msg_type = ProtoField.uint16("wcn36xx.msg_type", "msg_type", base.DEC, msg_type_strings)
f.msg_version = ProtoField.uint16("wcn36xx.msg_version", "msg_version")
f.len = ProtoField.uint32("wcn36xx.len", "len")
f.data = ProtoField.bytes("wcn36xx.data", "data")

f.scan_channel = ProtoField.uint8("wcn36xx.scan_channel", "scan_channel")
f.scan_dot11d_enabled = ProtoField.bool("wcn36xx.scan_dot11d_enabled", "dot11d_enabled")
f.scan_dot11d_resolved = ProtoField.bool("wcn36xx.scan_dot11d_resolved", "dot11d_resolved")
f.scan_channel_count  = ProtoField.uint8("wcn36xx.scan_channel_count", "channel_count", base.DEC)
f.scan_channels_i = ProtoField.uint8("wcn36xx.scan_channel", "scan_channel", base.DEC)
f.scan_active_min_ch_time = ProtoField.uint16("wcn36xx.scan_active_min_ch_time", "scan_active_min_ch_time", base.DEC)
f.scan_active_max_ch_time = ProtoField.uint16("wcn36xx.scan_active_max_ch_time", "scan_active_max_ch_time", base.DEC)
f.scan_passive_min_ch_time = ProtoField.uint16("wcn36xx.scan_active_min_ch_time", "scan_active_min_ch_time", base.DEC)
f.scan_passive_max_ch_time = ProtoField.uint16("wcn36xx.scan_active_max_ch_time", "scan_active_max_ch_time", base.DEC)
f.scan_phy_chan_bond_state = ProtoField.uint16("wcn36xx.scan_phy_chan_bond_state", "scan_phy_chan_bond_state", base.DEC, bond_state_strings)

f.nv_frag_number = ProtoField.uint16("wcn36xx.nv_frag_number", "frag_number", base.DEC)
f.nv_last_fragment = ProtoField.bool("wcn36xx.nv_last_fragment", "last_fragment")
f.nv_img_buffer_size = ProtoField.uint32("wcn36xx.nv_img_buffer_size", "nv_img_buffer_size", base.DEC)
f.nv_buffer = ProtoField.bytes("wcn36xx.nv_buffer", "nv_buffer")

f.beacon_filter_capability_info = ProtoField.uint16("wcn36xx.beacon_filter_capability_info", "capability_info", base.HEX)
f.beacon_filter_capability_mask = ProtoField.uint16("wcn36xx.beacon_filter_capability_mask", "capability_mask", base.HEX)
f.beacon_filter_beacon_interval = ProtoField.uint16("wcn36xx.beacon_filter_beacon_interval", "beacon_interval", base.DEC)
f.beacon_filter_ie_num = ProtoField.uint16("wcn36xx.beacon_filter_ie_num", "ie_num", base.DEC)
f.beacon_filter_bss_index = ProtoField.uint8("wcn36xx.beacon_filter_bss_index", "bss_index", base.DEC)
f.beacon_filter_reserved = ProtoField.uint8("wcn36xx.beacon_filter_reserved", "reserved", base.HEX)

f.beacon_filter_element_id = ProtoField.uint8("wcn36xx.beacon_filter_element_id", "element_id", base.DEC)
f.beacon_filter_check_ie_presence = ProtoField.uint8("wcn36xx.beacon_filter_check_ie_presence", "check_ie_presence", base.DEC)
f.beacon_filter_n = ProtoField.uint8("wcn36xx.beacon_filter_n", "offset", base.DEC)
f.beacon_filter_value = ProtoField.uint8("wcn36xx.beacon_filter_value", "value", base.HEX)
f.beacon_filter_bitmask = ProtoField.uint8("wcn36xx.beacon_bitmask", "bitmask", base.HEX)
f.beacon_filter_ref = ProtoField.uint8("wcn36xx.beacon_filter_ref", "ref", base.HEX)

f.update_cfg_len = ProtoField.uint32("wcn36xx.update_cfg_len", "len")
f.cfg_id = ProtoField.uint16("wcn36xx.cfg_id", "id", base.DEC, cfg_strings)
f.cfg_len = ProtoField.uint32("wcn36xx.update_cfg_len", "len")
f.cfg_pad_bytes = ProtoField.bytes("wcn36xx.cfg_pad_bytes", "pad_bytes")
f.cfg_reserve = ProtoField.bytes("wcn36xx.cfg_reserve", "reserve")
f.cfg_body = ProtoField.bytes("wcn36xx.cfg_body", "body")
f.cfg_value = ProtoField.uint32("wcn36xx.cfg_value", "value")

f.start_driver_type = ProtoField.uint32("wcn36xx.start_driver_type", "type", base.DEC, msg_type_strings)
f.start_len = ProtoField.uint32("wcn36xx.start_len", "len")

f.add_sta_self_addr = ProtoField.ether("wcn36xx.add_sta_self_addr", "addr")
f.add_sta_self_status = ProtoField.uint32("wcn36xx.add_sta_self_status", "status", base.HEX)

f.add_ba_session_sta_index = ProtoField.uint16("wcn36xx.add_ba_session_sta_index", "sta_index")
f.add_ba_session_mac_addr = ProtoField.ether("wcn36xx.add_ba_session_mac_addr", "mac_addr", base.HEX)
f.add_ba_session_dialog_token = ProtoField.uint8("wcn36xx.add_ba_session_dialog_token", "dialog_token")
f.add_ba_session_tid = ProtoField.uint8("wcn36xx.add_ba_session_tid", "tid")
f.add_ba_session_policy = ProtoField.uint8("wcn36xx.add_ba_session_policy", "policy")
f.add_ba_session_buffer_size = ProtoField.uint16("wcn36xx.add_ba_session_buffer_size", "buffer_size")
f.add_ba_session_timeout = ProtoField.uint16("wcn36xx.add_ba_session_timeout", "timeout")
f.add_ba_session_ssn = ProtoField.uint16("wcn36xx.add_ba_session_ssn", "ssn", base.HEX)
f.add_ba_session_direction = ProtoField.uint8("wcn36xx.add_ba_session_direction", "direction")

f.add_ba_session_id = ProtoField.uint8("wcn36xx.add_ba_session_id", "session_id")
f.add_ba_win_size = ProtoField.uint8("wcn36xx.add_ba_win_size", "win_size")
f.add_ba_reorder_on_chip = ProtoField.uint8("wcn36xx.add_ba_reorder_on_chip", "reorder_on_chip", base.DEC)

f.host_offload_type = ProtoField.uint8("wcn36xx.host_offload_type", "type", base.DEC, offload_type_strings)
f.host_offload_enable = ProtoField.bool("wcn36xx.host_offload_enable", "enable")
f.host_offload_ipv4 = ProtoField.ipv4("wcn36xx.host_offload_ipv4", "ipv4")
f.host_offload_ipv6 = ProtoField.ipv6("wcn36xx.host_offload_ipv6", "ipv6")
f.ns_offload_src_ipv6 = ProtoField.ipv6("wcn36xx.ns_offload_src_ipv6", "src_ipv6")
f.ns_offload_self_ipv6 = ProtoField.ipv6("wcn36xx.ns_offload_self_ipv6", "self_ipv6")
f.ns_offload_target_ipv6 = ProtoField.ipv6("wcn36xx.ns_offload_target_ipv6", "target_ipv6")
f.ns_offload_target_ipv6_2 = ProtoField.ipv6("wcn36xx.ns_offload_target_ipv6_2", "target_ipv6_2")
f.ns_offload_self_addr = ProtoField.ether("wcn36xx.ns_offload_target_self_addr", "self_addr")
f.ns_offload_valid = ProtoField.uint8("wcn36xx.ns_offload_valud", "valid", base.HEX)
f.ns_offload_reserved2 = ProtoField.uint8("wcn36xx.ns_offload_reserved2", "reserved2")
f.ns_offload_bss_index = ProtoField.uint8("wcn36xx.ns_offload_bss_index", "bss_index")
f.ns_offload_slot_index = ProtoField.uint32("wcn36xx.ns_offload_slot_index", "slot_index")

f.set_rssi_threshold_t1 = ProtoField.int8("wcn36xx.set_rssi_threshold_t1", "t1")
f.set_rssi_threshold_t2 = ProtoField.int8("wcn36xx.set_rssi_threshold_t2", "t2")
f.set_rssi_threshold_t3 = ProtoField.int8("wcn36xx.set_rssi_threshold_t3", "t3")
f.set_rssi_threshold_t1pos = ProtoField.bool("wcn36xx.set_rssi_threshold_t1pos", "t1posnotify")
f.set_rssi_threshold_t1neg = ProtoField.bool("wcn36xx.set_rssi_threshold_t1neg", "t1negnotify")
f.set_rssi_threshold_t2pos = ProtoField.bool("wcn36xx.set_rssi_threshold_t2pos", "t2posnotify")
f.set_rssi_threshold_t2neg = ProtoField.bool("wcn36xx.set_rssi_threshold_t2neg", "t2negnotify")
f.set_rssi_threshold_t3pos = ProtoField.bool("wcn36xx.set_rssi_threshold_t3pos", "t3posnotify")
f.set_rssi_threshold_t3neg = ProtoField.bool("wcn36xx.set_rssi_threshold_t3ned", "t3negnotify")

f.multicast_list_data_offset = ProtoField.uint8("wcn36xx.multicast_list_data_offset", "data_offset")
f.multicast_list_addr_count = ProtoField.uint32("wcn36xx.multicast_list_addr_count", "addr_count")
f.multicast_list_address = ProtoField.ether("wcn36xx.multicast_list_address", "address")
f.multicast_list_bss_index = ProtoField.uint8("wcn36xx.multicast_list_bss_index", "bss_index")

f.rcv_packet_filter_id = ProtoField.uint8("wcn36xx.rcv_packet_filter_id", "id")
f.rcv_packet_filter_type = ProtoField.uint8("wcn36xx.rcv_packet_filter_type", "type", base.HEX, filter_type_strings)
f.rcv_packet_filter_params_count = ProtoField.uint8("wcn36xx.rcv_packet_filter_id", "params_count")
f.rcv_packet_filter_coalesce_time = ProtoField.uint32("wcn36xx.rcv_packet_filter_coalesce_time", "coalesce_time")
f.rcv_packet_filter_bssid = ProtoField.uint8("wcn36xx.rcv_packet_filter_bssid", "bssid")
f.rcv_packet_filter_param_protocol_layer = ProtoField.uint8("wcn36xx.rcv_packet_filter_param_protocol_layer", "protocol_layer", base.HEX, filter_protocol_type_strings)
f.rcv_packet_filter_param_cmp_flag = ProtoField.uint8("wcn36xx.rcv_packet_filter_param_cmp_flag", "cmp_flag", base.HEX, filter_cmp_type_strings)
f.rcv_packet_filter_param_data_length = ProtoField.uint16("wcn36xx.rcv_packet_filter_param_data_length", "data_length")
f.rcv_packet_filter_param_data_offset = ProtoField.uint8("wcn36xx.rcv_packet_filter_param_data_offset", "data_offset")
f.rcv_packet_filter_param_reserved = ProtoField.uint8("wcn36xx.rcv_packet_filter_param_reserved", "reserved")
f.rcv_packet_filter_param_compare_data = ProtoField.bytes("wcn36xx.rcv_packet_filter_param_compare_data", "compare_data")
f.rcv_packet_filter_param_data_mask = ProtoField.bytes("wcn36xx.rcv_packet_filter_param_data_mask", "data_mask")

f.set_power_params_ignore_dtim = ProtoField.bool("wcn36xx.set_power_params_ignore_dtim", "ignore_dtim")
f.set_power_params_dtim_period = ProtoField.uint32("wcn36xx.set_power_params_dtim_period", "dtim_period")
f.set_power_params_listen_interval = ProtoField.uint32("wcn36xx.set_power_params_listen_interval", "listen_interval")
f.set_power_params_bcast_mcast_filter = ProtoField.uint32("wcn36xx.set_power_params_mcast_filter", "mcast_filter")
f.set_power_params_enable_bet = ProtoField.bool("wcn36xx.set_power_params_enable_bet", "enable_bet")
f.set_power_params_bet_interval = ProtoField.uint32("wcn36xx.set_power_params_bet_interval", "bet_interval")

f.ch_switch_channel_number = ProtoField.uint8("wcn36xx.ch_switch_channel_number", "channel")
f.ch_switch_local_power_constraint = ProtoField.uint8("wcn36xx.ch_switch_power_constraint", "power_constraint")
f.ch_switch_secondary_channel_offset = ProtoField.uint32("wcn36xx.ch_switch_secondary_channel_offset", "secondary_channel_offset", base.DEC, bond_state_strings)
f.ch_switch_tx_mgmt_power = ProtoField.uint8("wcn36xx.ch_switch_tx_mgmt_power", "tx_mgmt_power")
f.ch_switch_max_tx_power = ProtoField.uint8("wcn36xx.ch_switch_max_tx_power", "max_tx_power")
f.ch_switch_self_sta_mac_addr = ProtoField.ether("wcn36xx.ch_switch_self_sta_mac_addr", "self_sta_mac_addr")
f.ch_switch_bssid = ProtoField.ether("wcn36xx.ch_switch_bssid", "bssid")

f.init_scan_mode = ProtoField.uint32("wcn36xx.init_scan_mode", "mode", base.DEX, sys_mode_strings)
f.init_scan_bssid = ProtoField.ether("wcn36xx.init_scan_bssid", "bssid")
f.init_scan_notify = ProtoField.uint8("wcn36xx.init_scan_notify", "notify")
f.init_scan_frame_type = ProtoField.uint8("wcn36xx.init_scan_frame_type", "frame_type")
f.init_scan_frame_len = ProtoField.uint8("wcn36xx.init_scan_frame_len", "frame_len")

f.hal_mac_frame_ctl = ProtoField.uint16("wcn36xx.hal_mac_frame_ctl", "frame_ctl")
f.hal_mac_mgmt_hdr_duration_lo = ProtoField.uint8("wcn36xx.hal_mac_mgmt_hdr_duration_lo", "duration_lo")
f.hal_mac_mgmt_hdr_duration_hi = ProtoField.uint8("wcn36xx.hal_mac_mgmt_hdr_duration_hi", "duration_hi")
f.hal_mac_mgmt_hdr_da = ProtoField.bytes("wcn36xx.hal_mac_mgmt_hdr_da", "hdr_da")
f.hal_mac_mgmt_hdr_sa = ProtoField.bytes("wcn36xx.hal_mac_mgmt_hdr_sa", "hdr_sa")
f.hal_mac_mgmt_hdr_bssid = ProtoField.ether("wcn36xx.hal_mac_mgmt_hdr_bssid", "hdr_bssid")
f.hal_mac_mgmt_hdr_seq_ctl = ProtoField.uint16("wcn36xx.hal_mac_mgmt_hdr_seq_ctl", "seq_ctl")

f.hal_scan_entry_bss_index = ProtoField.bytes("wcn36xx.hal_scan_entry_bss_index", "bss_index")
f.hal_scan_entry_active_bss_count = ProtoField.uint8("wcn36xx.hal_scan_entry_active_bss_count", "active_bss_count")

f.del_sta_sta_index = ProtoField.uint8("wcn36xx.del_sta_sta_index", "sta_index")

f.del_bss_sta_index = ProtoField.uint8("wcn36xx.del_bss_sta_index", "sta_index")

f.set_link_st_bssid = ProtoField.ether("wcn36xx.set_link_st_bssid", "bssid")
f.set_link_st_state = ProtoField.uint32("wcn36xx.set_link_st_state", "state", base.DEC, link_state_strings)
f.set_link_st_self_mac_addr = ProtoField.ether("wcn36xx.set_link_st_state", "self_mac_addr")

f.join_bssid = ProtoField.ether("wcn36xx.join_bssid", "bssid")
f.join_channel = ProtoField.uint8("wcn36xx.join_channel", "local_power_constraint")
f.join_self_sta_mac_addr = ProtoField.ether("wcn36xx.join_self_sta_mac_addr", "self_sta_mac_addr")
f.join_local_power_constraint = ProtoField.uint8("wcn36xx.join_local_power_constraint", "local_power_constraint")
f.join_secondary_channel_offset = ProtoField.uint32("wcn36xx.join_secondary_channel_offset", "secondary_channel_offset", base.DEC, bond_state_strings)
f.join_link_state = ProtoField.uint32("wcn36xx.join_link_st_state", "state", base.DEC, link_state_strings)
f.join_max_tx_power = ProtoField.int8("wcn36xx.join_max_tx_power", "max_tx_power")

f.rsp_status = ProtoField.uint32("wcn36xx.rsp_status", "status", base.HEX)
f.start_rsp_status = ProtoField.uint16("wcn36xx.start_rsp_status", "status", base.HEX)
f.start_rsp_fw_major = ProtoField.uint8("wcn36xx.start_rsp_fw_major", "fw_major")
f.start_rsp_fw_minor = ProtoField.uint8("wcn36xx.start_rsp_fw_minor", "fw_minor")
f.start_rsp_fw_version = ProtoField.uint8("wcn36xx.start_rsp_fw_version", "fw_version")
f.start_rsp_fw_revision = ProtoField.uint8("wcn36xx.start_rsp_fw_revision", "fw_revision")

f.tl_flush_ac_sta_id = ProtoField.uint8("wcn36xx.tl_flush_ac_sta_id", "sta_id")
f.tl_flush_ac_tid = ProtoField.uint8("wcn36xx.tl_flush_ac_tid", "tid")

f.set_max_tx_power_rsp_power = ProtoField.uint8("wcn36xx.set_max_tx_power_rsp_power", "power")

f.trigger_ba_rsp_bssid = ProtoField.ether("wcn36xx.trigger_ba_rsp_bssid", "bssid")
f.trigger_ba_rsp_candidate_cnt = ProtoField.uint16("wcn36xx.trigger_ba_rsp_candidate_cnt", "candidate_cnt")

f.enable_radar_rsp_bssid = ProtoField.ether("wcn36xx.trigger_ba_rsp_bssid", "bssid")
