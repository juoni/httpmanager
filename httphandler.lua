local mainResourceName = GetCurrentResourceName()

-- Default options for new HTTP handlers
local defaultOptions = {
	rootDir = "files",
	directoryIndex = "index.html",
	log = false,
	logFile = "log.json",
	errorPages = {},
	mimeTypes = {},
	routes = {}
}

-- The size of each block of a response
local blockSize = 8192

local function createHttpHandler(options)
	local resourceName = GetInvokingResource() or GetCurrentResourceName()
	local resourcePath = GetResourcePath(resourceName)

	if type(options) ~= "table" then
		options = {}
	end

	for key, defaultValue in pairs(defaultOptions) do
		if not options[key] then
			options[key] = defaultValue
		end
	end

	local handlerLog

	if options.log then
		handlerLog = json.decode(LoadResourceFile(resourceName, options.logFile)) or {}
	end

	local function getMimeType(path)
		local extension = path:match("^.+%.(.+)$")

		if options.mimeTypes[extension] then
			return options.mimeTypes[extension]
		elseif MimeTypes[extension] then
			return MimeTypes[extension]
		else
			return "application/octet-stream"
		end
	end

	local function sendError(res, code)
		res.writeHead(code, {["Content-Type"] = "text/html"})

		local resource, path

		if options.errorPages[code] then
			resource = resourceName
			path = options.rootDir .. "/" .. options.errorPages[code]
		else
			resource = mainResourceName
			path = defaultOptions.rootDir .. "/" .. code .. ".html"
		end

		local data = LoadResourceFile(resource, path)

		if data then
			res.send(data)
		else
			res.send("Error: " .. code)
		end
	end

	local function log(entry)
		if not handlerLog then
			return
		end

		entry.time = os.time()

		table.insert(handlerLog, entry)

		table.sort(handlerLog, function(a, b)
			return a.time < b.time
		end)

		SaveResourceFile(resourceName, options.logFile, json.encode(handlerLog), -1)
	end

	local function sendFile(req, res, path)
		local relativePath = options.rootDir .. path
		local absolutePath = resourcePath .. "/" .. relativePath

		local mimeType = getMimeType(absolutePath)

		local f = io.open(absolutePath, "rb")

		local statusCode

		if f then
			local startBytes, endBytes

			if req.headers.Range then
				local s, e = req.headers.Range:match("^bytes=(%d+)-(%d+)$")
				startBytes = tonumber(s)
				endBytes = tonumber(e)
			end

			if not startBytes then
				startBytes = 0
			end

			local fileSize = f:seek("end")
			f:seek("set", startBytes)

			if not endBytes then
				endBytes = fileSize - 1
			end

			local headers = {
				["Content-Type"] = mimeType,
				["Transfer-Encoding"] = "identity",
				["Accept-Ranges"] = "bytes"
			}

			if req.headers.Range then
				statusCode = 206

				headers["Content-Range"] = ("bytes %d-%d/%d"):format(startBytes, endBytes, fileSize)
				headers["Content-Length"] = tostring(endBytes - startBytes + 1)
			else
				statusCode = 200

				headers["Content-Length"] = tostring(fileSize)
			end

			res.writeHead(statusCode, headers)

			if req.method ~= "HEAD" then
				while true do
					local block = f:read(blockSize)
					if not block then break end
					res.write(block)
				end
			end

			res.send()

			f:close()
		else
			statusCode = 404

			sendError(res, statusCode)
		end

		log {
			type = "file",
			path = req.path,
			address = req.address,
			method = req.method,
			headers = req.headers,
			status = statusCode,
			file = absolutePath
		}

		return statusCode
	end

	return function(req, res)
		local url = Url.normalize(req.path)

		for pattern, callback in pairs(options.routes) do
			local matches = {url.path:match(pattern)}

			if #matches > 0 then
				req.url = url

				res.sendError = function(code)
					sendError(res, code)
				end

				res.sendFile = function(path)
					sendFile(req, res, path)
				end

				local helpers = {
					log = function(entry)
						entry.type = "message"
						entry.route = pattern
						log(entry)
					end
				}

				callback(req, res, helpers, table.unpack(matches))

				log {
					type = "route",
					route = pattern,
					path = req.path,
					address = req.address,
					method = req.method,
					headers = req.headers,
				}

				return
			end
		end

		if options.rootDir then
			if url.path:sub(-1) == "/" then
				url.path = url.path .. options.directoryIndex
			end

			sendFile(req, res, url.path)
		else
			sendError(res, 404)
		end
	end
end

exports("createHttpHandler", createHttpHandler)