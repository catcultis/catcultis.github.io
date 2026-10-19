-- Catcul: school public IP confirmed by the administrator in this conversation.
-- Run in Supabase SQL Editor AFTER catcul-school-upgrade.sql.
-- Adds one exact IPv4 address; preserves other configured networks.
-- Safe to rerun. Does not change the Study Mode passcode or unlock students.
-- The catcul-school Edge Function must be deployed for automatic detection.

update catcul.school_config
set campus_networks = case
      when '129.222.205.220/32'::cidr = any(campus_networks)
        then campus_networks
      else array_append(campus_networks, '129.222.205.220/32'::cidr)
    end,
    updated_at = now()
where id = true
returning campus_networks;
