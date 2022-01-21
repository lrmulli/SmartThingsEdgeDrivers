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

local capabilities = require "st.capabilities"
local clusters  = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local mgmt_bind_resp = require "st.zigbee.zdo.mgmt_bind_response"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"
local log = require "log"
local Level = clusters.Level
local OnOff = clusters.OnOff
local ColorControl = clusters.ColorControl
local PowerConfiguration = clusters.PowerConfiguration
local zigbee_utils = require "zigbee_utils"
local Groups = clusters.Groups

local logger = capabilities["universevoice35900.log"]

--[[
The EcoSmart remote has 4 buttons. We've chosen to only support "pushed" events on all buttons even though technically
we could support "held" on buttons 2 and 3. This gives a more consistent and less confusing user experience.

Button 1
--------

The first button sends alternating On and Off commands. We translate both commands to button1 `pushed` events.

Button 2
--------

The second button sends MoveToLevel commands when pressed, Move commands when held and Stop when let go. We translate
both MoveToLevel and Move to button2 `pushed` events and ignore Stop commands.

Button 3
--------

The third button sends MoveToColorTemperature commands when pressed and MoveColorTemperature commands when held/let go.
We generate button3 `pushed` events but only if not preceded by a MoveToLevelWithOnOff.

Button 4
--------

The fourth button sends a MoveToLevelWithOnOff command followed by MoveToColorTemperature. We generate button4 `pressed`
events when we receive the MoveToLevelWithOnOff command and we ignore the following MoveToColorTemperature command so
that we don't generate an erroneous button3 `pushed` event.
--]]
local function group_bind(device)
  local grp = device.preferences.group
  local rmv = device.preferences.remove
  if(rmv > 0) then
    log.info("Attempting remove group :"..rmv)
    zigbee_utils.send_unbind_request(device, OnOff.ID, rmv)
    zigbee_utils.send_unbind_request(device, Level.ID, rmv)
    zigbee_utils.send_unbind_request(device, ColorControl.ID, rmv)
  end
  if(grp > 0) then
    log.info("Attempting add group :"..grp)
    zigbee_utils.send_bind_request(device, OnOff.ID, grp)
    zigbee_utils.send_bind_request(device, Level.ID, grp)
    zigbee_utils.send_bind_request(device, ColorControl.ID, grp)
  end
  zigbee_utils.send_read_binding_table(device)
end


local function device_info_changed(driver, device, event, args)
  -- Did my preference value change
    if args.old_st_store.preferences.group ~= device.preferences.group then
      log.info("Group Id Changed: "..device.preferences.group)
      local group = device.preferences.group
      local oldgroup = args.old_st_store.preferences.group
      group_bind(device)
    end
end

local fields = {
  IGNORE_MOVETOCOLORTEMP = "ignore_next_movetocolortemperature"
}

local emit_pushed_event = function(button_name, device)
  local additional_fields = {
    state_change = true
  }
  if (device.preferences.verbosegrouplog == true) then
    log.info("Fetching Binding Table")
    zigbee_utils.send_read_binding_table(device)
  end
  if (device.preferences.aggressivebind == true) then
    log.info("Aggressive Bind on button press attempt")
    group_bind(device)
  end
  local event = capabilities.button.button.pushed(additional_fields)
  local comp = device.profile.components[button_name]
  if comp ~= nil then
    device:emit_component_event(comp, event)
  else
    log.warn("Attempted to emit button event for unknown button: " .. button_name)
  end
end

local function moveToColorTemperature_handler(driver, device, zb_rx)
  if device:get_field(fields.IGNORE_MOVETOCOLORTEMP) ~= true then
    emit_pushed_event("button3", device)
  end
  device:set_field(fields.IGNORE_MOVETOCOLORTEMP, false)
end

local function moveColorTemperature_handler(driver, device, zb_rx)
  if zb_rx.body.zcl_body.move_mode.value ~= ColorControl.types.CcMoveMode.Stop then
      emit_pushed_event("button3", device)
  end
end

local function moveToLevelWithOnOff_handler(driver, device, zb_rx)
  device:set_field(fields.IGNORE_MOVETOCOLORTEMP, true)
  emit_pushed_event("button4", device)
end

local do_refresh = function(self, device)
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  log.info("Doing Refresh")
  zigbee_utils.print_clusters(device)
  zigbee_utils.send_read_binding_table(device)
  device:send(Groups.server.commands.GetGroupMembership(device, {}))
  device:send(Groups.server.commands.ViewGroup(device,device.preferences.group))
end

local do_configure = function(self, device)
  do_refresh(self, device)
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 30, 21600, 1))
  device:send(device_management.build_bind_request(device, OnOff.ID, self.environment_info.hub_zigbee_eui))
  -- The device reports button presses to this group but it can't be read from the binding table
  self:add_hub_to_zigbee_group(0x4003)
end

local function zdo_binding_table_handler(driver, device, zb_rx)
  local groups = ""
  for _, binding_table in pairs(zb_rx.body.zdo_body.binding_table_entries) do
    print("Zigbee Group is:"..binding_table.dest_addr.value)
    if binding_table.dest_addr_mode.value == binding_table.DEST_ADDR_MODE_SHORT then
      -- send add hub to zigbee group command
      driver:add_hub_to_zigbee_group(binding_table.dest_addr.value)
      print("Adding to zigbee group: "..binding_table.dest_addr.value)
      groups = groups..binding_table.cluster_id.value.."("..binding_table.dest_addr.value.."),"
    else
      driver:add_hub_to_zigbee_group(0x0000)
    end
  end
  log.info("GROUPS: "..groups)
  device:emit_event(logger.logger("Processing Binding Table"))
  device:emit_event(logger.logger("GROUPS: "..groups))
end


local ecosmart_button = {
  NAME = "EcoSmart Button",
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    }
  },
  zigbee_handlers = {
    zdo = {
      [mgmt_bind_resp.MGMT_BIND_RESPONSE] = zdo_binding_table_handler
    },
    cluster = {
      [OnOff.ID] = {
        [OnOff.server.commands.Off.ID] = function(driver, device, zb_rx) emit_pushed_event("button1", device) end,
        [OnOff.server.commands.On.ID] = function(driver, device, zb_rx) emit_pushed_event("button1", device) end
      },
      [Level.ID] = {
        [Level.server.commands.MoveToLevel.ID] = function(driver, device, zb_rx) emit_pushed_event("button2", device) end,
        [Level.server.commands.Move.ID] = function(driver, device, zb_rx) emit_pushed_event("button2", device) end,
        [Level.server.commands.MoveToLevelWithOnOff.ID] = moveToLevelWithOnOff_handler
      },
      [ColorControl.ID] = {
        [ColorControl.server.commands.MoveToColorTemperature.ID] = moveToColorTemperature_handler,
        [ColorControl.server.commands.MoveColorTemperature.ID] = moveColorTemperature_handler,
      }
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
    infoChanged = device_info_changed
  },
  can_handle = function(opts, driver, device, ...)
    return device:get_manufacturer() == "LDS" and device:get_model() == "ZBT-CCTSwitch-D0001"
  end
}

return ecosmart_button
