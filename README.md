ISPQuotaCheck
=============

## Description
Produces a one-line summary of your ISP download usage (via your ISP's
web-service).

## isp_quota_check.rb

### Usage
```
Usage:
  isp_quota_check.rb  --help|-h
  isp_quota_check.rb  --setup|-s
  isp_quota_check.rb

Run with the --setup (or -s) option initially to configure your ISP username
and password.

Also configure constants in module IspQuotaCheckCommon for your ISP:
- ISP_WS_BASE_URI
- ISP_WS_SERVICE_XPATH
- ISP_WS_USAGE_XPATH

Then you can obtain ISP usage information by running isp_quota_check.rb
(without any options).
```

### Features
- Obtains current ISP download-usage statistics about your plan(s).
- Stores ISP username and password configuration information in a file
  so the application will run without entering this information each time.
- By default, ISP username and password configuration information is
  encrypted before storing in a file. The level of security is adequate
  to protect the information from the casual observer (but is weak and
  should not be used for any serious purpose).
- Suitable for running as a Unix/Linux cron job.

