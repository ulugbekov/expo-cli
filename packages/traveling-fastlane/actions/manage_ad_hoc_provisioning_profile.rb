require 'spaceship'
require 'json'
require 'base64'
require 'set'
require_relative 'funcs'

ENV['SPACESHIP_AVOID_XCODE_API'] = '1'

def find_dist_cert(serialNumber, isEnterprise)
  certs = if isEnterprise == 'true'
    Spaceship::Portal.certificate.in_house.all
  else
    Spaceship::Portal.certificate.production.all
  end

  if $certSerialNumber == '__last__'
    certs.last
  else
    certs.find do |c|
      c.raw_data['serialNum'] == $certSerialNumber
    end
  end
end

def get_registered_udids()
  all_iphones = Spaceship.device.all_iphones
  already_added = all_iphones.select { |d| d.enabled? and udids.include?(d.udid) }
  already_added.map { |i| i.udid }
end

def register_missing_devices(udids)
  all_iphones = Spaceship.device.all_iphones
  already_added = all_iphones.select { |d| d.enabled? and udids.include?(d.udid) }
  already_added_udids = already_added.map { |i| i.udid }

  devices = [*already_added]

  udids_to_add = udids - already_added_udids
  udids_to_add.each { |udid|
    devices.push Spaceship.device.create!(name: "iPhone (added by Expo)", udid: udid)
  }

  devices
end

def list()
  profiles = find_profile_by_bundle_id($bundleId)
  profiles.map{ |profile|
    {
      id: profile.id,
      name: profile.name
      expires: profile.expires.to_time.to_i,
      app: profile.app.name,
      certificates: profile.certificates.map{ |cert|
        {
          serialNumber: cert.raw_data['serialNumber'],
        }
      }
    }
  }
end

def find_profile_by_id(id)
  profiles = find_profile_by_bundle_id($bundleId)
  profiles.select{ |profile| profile.id == id }.last
end

def find_profile_by_bundle_id(bundle_id)
  Spaceship::Portal.provisioning_profile.ad_hoc.find_by_bundle_id(bundle_id: bundle_id)
end

def create(dist_cert)
  devices = get_registered_udids()
  new_profile = Spaceship::Portal.provisioning_profile.ad_hoc.create!(
    bundle_id: $bundleId,
    certificate: dist_cert,
    devices: devices
  )
  profile = download_provisioning_profile(new_profile)
  {
    provisioningProfileId: profile[:id],
    provisioningProfile: profile[:content],
  }
end

def revoke(ids)
  profiles = find_profile_by_bundle_id($bundleId)

  # find profiles associated with our development cert
  profiles_to_delete = profiles.select{ |profile|
    ids.any?{|id| id == profile.id}
  }

  profiles_to_delete.each { |profile| profile.delete! }
end

def add_dist_cert_to_profile(profile_id, cert_serial_number)
  profile = find_profile_by_dev_portal_id(profile_id)
  if profile == nil
    # If the adhoc profile doesn't exist, the user must have deleted it, we can't do anything here :(
    raise RuntimeError, `Unable to find adhoc profile with id #{profile_id}`
  end

  if profile.certificates.any?{|cert| cert.raw_data['serialNumber'] == cert_serial_number}
    profile # profile is already associated with cert
  else
    # append the certificate and update the profile 
    dist_cert = find_dist_cert(cert_serial_number, in_house?($teamId))
    profile.certificates.push(dist_cert)
    profile.update!
  end
end

def add_udids_to_profile(profile_id, udids)
  # Then we register all missing devices on the Apple Developer Portal. They are identified by UDIDs.
  devices = register_missing_devices(udids)

  # Then we try to find an already existing provisioning profile for the App ID.
  existing_profile = find_profile_by_id(profile_id)

  if existing_profile == nil
    raise RuntimeError, `Unable to find adhoc profile with id #{profile_id}`
  elsif !existing_profile.valid?
    raise RuntimeError, `Adhoc profile with id #{profile_id} is invalid`
  end

  # We need to verify whether the existing profile includes all user's devices.
  device_udids_in_profile = Set.new(existing_profile.devices.map { |d| d.udid })
  all_device_udids = Set.new(udids)
  if device_udids_in_profile == all_device_udids
    { didUpdateProfile: false }
  else
    # We need to add new devices to the list and create a new provisioning profile.
    existing_profile.devices = devices
    updated_profile = existing_profile.update!
    profile = download_provisioning_profile(updated_profile)
    { 
      didUpdateProfile: true,         
      provisioningProfileId: profile[:id],
      provisioningProfile: profile[:content], 
    }
  end
end

def download_provisioning_profile(profile)
  profile_content = profile.download
  {
    id: profile.id,
    content: Base64.encode64(profile_content),
  }
end

def in_house?(team_id)
  team = Spaceship::Portal.client.teams.find { |t| t['teamId'] == team_id }
  team['type'] === 'In-House'
end

$teamId, $bundleId, $action, *$actionArgs  = ARGV
$result = nil

with_captured_output{
  begin
    if ENV['APPLE_ID'] && ENV['APPLE_PASSWORD']
      Spaceship::Portal.login(ENV['APPLE_ID'], ENV['APPLE_PASSWORD'])
    elsif ENV['FASTLANE_SESSION']
      # Spaceship::Portal doesn't seem to have a method for initializing portal client
      # without supplying Apple ID username/password (or i didn't find one). Fortunately,
      # we can pass here whatever we like, as long as we set FASTLANE_SESSION env variable.
      Spaceship::Portal.login('fake-login', 'fake-password')
    else
      raise ArgumentError, 'Must pass in an Apple Session or Apple login/password'
    end
    Spaceship::Portal.client.team_id = $teamId
    
    if $action == 'create'
      $certSerialNumber, * = $actionArgs
      dist_cert = find_dist_cert($certSerialNumber, in_house?($teamId))
      if dist_cert == nil
        # If the distribution certificate doesn't exist, the user must have deleted it, we can't do anything here :(
        raise RuntimeError, `Unable to find distribution certificate with serial number #{$certSerialNumber}`
      end
      profile = create(dist_cert)
      $result = { result: 'success', **profile }
    elsif $action = 'download'
      $profileId, * = $actionArgs
      existing_profile = find_profile_by_id($profileId)
      profile = = download_provisioning_profile(existing_profile)
      $result = {
        result: 'success',
        provisioningProfileId: profile[:id],
        provisioningProfile: profile[:content],
      }
    elsif $action == 'list'
      $result = {
        result: 'success',
        profiles: list(),
      }
    elsif $action == 'revoke'
      $profileIdsString, * = $actionArgs
      $profileIds = $profileIdsString.split(',')
      revoke($profileIds)
      $result = { result: 'success' }
    elsif $action == 'add-dist-cert'
      $profileId, $certSerialNumber = $actionArgs
      add_dist_cert_to_profile($profileId, $certSerialNumber)
      $result = { result: 'success' }
    elsif $action  == 'add-udid'
      $profileId, $udidsString = $actionArgs
      $udids = $udidsString.split(',')
      update_result = add_udids_to_profile($profileId, $udids)
      $result = {
        result: 'success',
        **update_result,
      }
    else 
      raise ArgumentError, `Invalid action #{$action}`
    end
  rescue Spaceship::Client::UnexpectedResponse => e
    $result = {
      result: 'failure',
      reason: 'Unexpected response',
      rawDump: e.error_info || dump_error(e)
    }
  rescue Spaceship::Client::InvalidUserCredentialsError => e
    $result = {
      result: 'failure',
      type: 'session-expired',
      reason: 'Apple Session expired',
    }
  rescue Exception => e
    $result = {
      result: 'failure',
      reason: e.message || 'Unknown reason',
      rawDump: dump_error(e)
    }
  end
}

$stderr.puts JSON.generate($result)
