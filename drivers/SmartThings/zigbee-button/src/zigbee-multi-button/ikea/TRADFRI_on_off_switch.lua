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
local clusters = require "st.zigbee.zcl.clusters"
local log = require "log"

local Level = clusters.Level
local OnOff = clusters.OnOff
local PowerConfiguration = clusters.PowerConfiguration

local zigbee_utils = require "zigbee_utils"
local Groups = clusters.Groups

local function device_info_changed(driver, device, event, args)
  -- Did my preference value change
  if args.old_st_store.preferences.group ~= device.preferences.group then
    log.info("Group Id Changed: "..device.preferences.group)
    local group = device.preferences.group
    local oldgroup = args.old_st_store.preferences.group
    zigbee_utils.send_unbind_request(device, OnOff.ID, oldgroup)
    zigbee_utils.send_unbind_request(device, Level.ID, oldgroup)
    if(group > 0) then
      zigbee_utils.send_bind_request(device, OnOff.ID, group)
      zigbee_utils.send_bind_request(device, Level.ID, group)
    else if (group == 0) then
      device:send(Groups.server.commands.RemoveAllGroups(device, {}))
    end
  end
end


function build_button_handler(button_name, pressed_type)
  return function(driver, device, zb_rx)
    local additional_fields = {
      state_change = true
    }
    local event = pressed_type(additional_fields)
    local comp = device.profile.components[button_name]
    if comp ~= nil then
      device:emit_component_event(comp, event)
    else
      log.warn("Attempted to emit button event for unknown button: " .. button_name)
    end
  end
end

local on_off_switch = {
  NAME = "On/Off Switch",
  zigbee_handlers = {
    cluster = {
      [OnOff.ID] = {
        [OnOff.server.commands.Off.ID] = build_button_handler("button1", capabilities.button.button.pushed),
        [OnOff.server.commands.On.ID] = build_button_handler("button2", capabilities.button.button.pushed)
      },
      [Level.ID] = {
        [Level.server.commands.Move.ID] = build_button_handler("button1", capabilities.button.button.held),
        [Level.server.commands.MoveWithOnOff.ID] = build_button_handler("button2", capabilities.button.button.held)
      },
    }
  },
  lifecycle_handlers = {
    infoChanged = device_info_changed
  },
  can_handle = function(opts, driver, device, ...)
    return device:get_model() == "TRADFRI on/off switch"
  end
}

return on_off_switch
