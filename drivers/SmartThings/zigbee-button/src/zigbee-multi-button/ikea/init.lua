-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local constants = require "st.zigbee.constants"
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local messages = require "st.zigbee.messages"
local mgmt_bind_resp = require "st.zigbee.zdo.mgmt_bind_response"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"
local zdo_messages = require "st.zigbee.zdo"

local OnOff = clusters.OnOff
local PowerConfiguration = clusters.PowerConfiguration
local zigbee_utils = require "zigbee_utils"
local Groups = clusters.Groups
local log = require "log"
local capabilities = require "st.capabilities"
local utils = require "st.utils"
local zcl_clusters = require "st.zigbee.zcl.clusters"

local logger = capabilities["universevoice35900.log"]

local do_refresh = function(self, device)
  log.info("Doing Refresh - "..device:get_model())
  log.info("Hub Address: "..constants.HUB.ADDR)
  log.info("Hub Endpoint: "..constants.HUB.ENDPOINT)
  zigbee_utils.print_clusters(device)
  zigbee_utils.send_read_binding_table(device)
  device:send(Groups.server.commands.GetGroupMembership(device, {}))
  device:send(Groups.server.commands.ViewGroup(device,device.preferences.group))
end

local do_configure = function(self, device)
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, OnOff.ID, self.environment_info.hub_zigbee_eui))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 30, 21600, 1))
  -- Read binding table
  local addr_header = messages.AddressHeader(
    constants.HUB.ADDR,
    constants.HUB.ENDPOINT,
    device:get_short_address(),
    device.fingerprinted_endpoint_id,
    constants.ZDO_PROFILE_ID,
    mgmt_bind_req.BINDING_TABLE_REQUEST_CLUSTER_ID
  )
  local binding_table_req = mgmt_bind_req.MgmtBindRequest(0) -- Single argument of the start index to query the table
  local message_body = zdo_messages.ZdoMessageBody({
                                                   zdo_body = binding_table_req
                                                 })
  local binding_table_cmd = messages.ZigbeeMessageTx({
                                                     address_header = addr_header,
                                                     body = message_body
                                                   })
  device:send(binding_table_cmd)
end

local function zdo_binding_table_handler(driver, device, zb_rx)
  local groups = ""
  local devicebinds = ""
  for _, binding_table in pairs(zb_rx.body.zdo_body.binding_table_entries) do
    --print("Zigbee Group is:"..binding_table.dest_addr.value)
    if binding_table.dest_addr_mode.value == binding_table.DEST_ADDR_MODE_SHORT then
      -- send add hub to zigbee group command
      driver:add_hub_to_zigbee_group(binding_table.dest_addr.value)
      --print("Adding to zigbee group: "..binding_table.dest_addr.value)
      groups = groups..binding_table.cluster_id.value.."("..binding_table.dest_addr.value.."),"
    else
      driver:add_hub_to_zigbee_group(0x0000)
      local binding_info = {}
      binding_info.cluster_id = binding_table.cluster_id.value
      binding_info.dest_addr = utils.get_print_safe_string(binding_table.dest_addr.value)
      binding_info.dest_addr = binding_info.dest_addr:gsub("%\\x", "")
      devicebinds = devicebinds..utils.stringify_table(binding_info)
    end
  end
  log.info("GROUPS: "..groups)
  log.info("DEVICE BINDS: "..devicebinds)
  device:emit_event(logger.logger("Processing Binding Table"))
  device:emit_event(logger.logger("GROUPS: "..groups))
  device:emit_event(logger.logger("DEVICE BINDS: "..devicebinds))
end


local ikea_of_sweden = {
  NAME = "IKEA Sweden",
  lifecycle_handlers = {
    doConfigure = do_configure
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    }
  },
  zigbee_handlers = {
    zdo = {
      [mgmt_bind_resp.MGMT_BIND_RESPONSE] = zdo_binding_table_handler
    },
  },
  sub_drivers = {
    require("zigbee-multi-button.ikea.TRADFRI_remote_control"),
    require("zigbee-multi-button.ikea.TRADFRI_on_off_switch"),
    require("zigbee-multi-button.ikea.TRADFRI_open_close_remote"),
    require("zigbee-multi-button.ikea.STYRBAR_remote_control"),
  },
  can_handle = function(opts, driver, device, ...)
    return device:get_manufacturer() == "IKEA of Sweden" or device:get_manufacturer() == "KE"
  end
}

return ikea_of_sweden
