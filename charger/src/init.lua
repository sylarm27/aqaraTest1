local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local utils = require "st.utils"
local ZigbeeDriver = require "st.zigbee"
local constants = require "st.zigbee.constants"
local defaults = require "st.zigbee.defaults"
local log = require "log"
local xiaomi_utils = require "xiaomi_utils"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local json = require "dkjson"

local function added_handler(self, device)
  -- https://github.com/veonua/SmartThingsEdge-Xiaomi/issues/6
  device:set_field(constants.SIMPLE_METERING_DIVISOR_KEY, 10, {persists= true})        -- Current Summation Delivered
  device:set_field(constants.ELECTRICAL_MEASUREMENT_DIVISOR_KEY, 10, {persists= true}) -- Active Power
end

local function temp_attr_handler(driver, device, value, zb_rx)
  device:emit_event(capabilities.temperatureMeasurement.temperature({ value = value.value, unit = "C"}) )
end

local function attr_handler0C(driver, device, e_value, zb_rx)
  local endpoint = zb_rx.address_header.src_endpoint.value
  local value = utils.round(e_value.value * 100)/100.0
  
  if endpoint == 2 then
    device:emit_event( capabilities.powerMeter.power({value=value, unit="W"}) )

    local charging_state = ""
    if value < 0.1 then
      charging_state = "powerOff"
    elseif value < 3.0 then
      charging_state = "idle"
    elseif value > 13.0 then
      charging_state = "charging"
    else
      charging_state = "pause"
    end

    device:emit_event( capabilities.robotCleanerMovement.robotCleanerMovement({value=charging_state}) )

  elseif endpoint == 3 then
    device:emit_event( capabilities.energyMeter.energy({value=value, unit="Wh"}) )
  end
end

local function info_changed(driver, device, event, args)
  log.info(">>info changed: " .. tostring(event))
  log.info(json.encode(device.zigbee_endpoints))

  for id, value in pairs(device.preferences) do
    if args.old_st_store.preferences[id] ~= value then
      local value = device.preferences[id]
      local cluster_id = xiaomi_utils.OppleCluster
      
      log.info("preferences changed: " .. id .. " " .. tostring(value))

      local data_type
      local payload
      local attr
      
      if id == "stse.restorePowerState" then
        payload = data_types.Boolean(value)
        attr = 0x0201
      elseif id == "autoOff" then
        payload = data_types.Boolean(value)
        attr = 0x0202
      elseif id == "stse.turnOffIndicatorLight" then
        if device:get_model() == "ZNCZ11LM" then
          payload = data_types.OctetString( value and 
            { 0xaa, 0x80, 0x05, 0xd1, 0x47, 0x00, 0x03, 0x10, 0x00} or
            { 0xaa, 0x80, 0x05, 0xd1, 0x47, 0x01, 0x03, 0x10, 0x01} )
          local cluster_id = zcl_clusters.basic_id
        else
          payload = data_types.Boolean(value)
          attr = 0x0203
        end

      elseif id == "overloadProtection" then
        local sign = 0
        local mantissa, exponent = math.frexp(value)
        mantissa = mantissa * 2 - 1
        exponent = exponent - 1
        
        payload = data_types.SinglePrecisionFloat(sign, exponent, mantissa)
        data_type = data_types.SinglePrecisionFloat
        attr = 0x020b
      end

      if payload then
        local cmd = cluster_base.write_attribute(device, data_types.ClusterId(cluster_id), data_types.AttributeId(attr), payload)
        log.info("writing attribute: " .. tostring(cmd) )
        device:send(cmd )
      end
    end
  end
end

local plug_driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,    
    capabilities.temperatureAlarm,
    capabilities.voltageMeasurement,
    capabilities.refresh,
  },
  lifecycle_handlers = {
    added = added_handler,
    infoChanged = info_changed,
  },
  zigbee_handlers = {
    global = {},
    cluster = {},
    attr = {
      [zcl_clusters.basic_id] = xiaomi_utils.basic_id,
      [zcl_clusters.DeviceTemperatureConfiguration.ID] = {
        [zcl_clusters.DeviceTemperatureConfiguration.attributes.CurrentTemperature.ID] = temp_attr_handler,
      },
      [zcl_clusters.analog_input_id] = {
        [zcl_clusters.AnalogInput.attributes.PresentValue.ID] = attr_handler0C
      }
    }
  },
  
}

defaults.register_for_default_handlers(plug_driver_template, plug_driver_template.supported_capabilities)
local plug = ZigbeeDriver("Charger", plug_driver_template)
plug:run()
