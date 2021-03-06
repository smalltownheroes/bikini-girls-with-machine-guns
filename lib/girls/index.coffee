{EventEmitter} = require 'events'
async          = require 'async'
joi            = require 'joi'
_              = require 'lodash'

path           = require 'path'
fs             = require 'fs'
childProcess   = require 'child_process'

schema         = require './schema'
S3Store        = require '../s3'
log            = require '../log'

class Girls extends EventEmitter

	constructor: (options) ->
		super
		@s3Store = new S3Store()

	generatePromise: (input) ->
		p = new Promise (resolve, reject) =>
			@generateTask(input) (err, result) ->
				if err?
					reject err
				else
					resolve result

	generateTask: (input) ->
		(cb) =>
			@generate input, (err, results) ->
				if err?
					cb err
				else
					cb null, results

	generate: (input, cb) ->
		work = []
		work.push (callb) =>
			@_validate input, callb
		work.push (callb) =>
			@_generateResult input, callb
		async.waterfall work, (err, result) =>
			if err?
				if cb?
					cb err
				else
					log.info err, 'Girls::error'
					@emit 'error', err
			else
				if cb?
					cb? null, result
				else
					# log.info result, 'Girls::success'
					@emit 'finish', result

	_generateResult: (input, cb) ->
		@_callPhantom input, (err, output) ->
			cb? null, output

	_validate: (input, cb) ->
		joi.validate input, schema.input, {abortEarly: false, allowUnknown: true}, (bodyErr, value) =>
			if bodyErr?
				@_handleValidationError bodyErr, (handleErr) ->
					cb handleErr
			else
				cb null

	_handleValidationError: (err, cb) ->
		validations = _.map err.details, 'message'
		badRequest =
			status: 400
			name: 'BAD_REQUEST'
			message: "#{(message for message in validations).join(', ')}"
		cb badRequest

	_getPhantomFileName: (cb) ->
		nodeModulesPath = path.join(__dirname, '../../node_modules/phantomjs')
		fs.exists nodeModulesPath, (exists) ->
			if exists
				cb null, path.join(__dirname, '../../node_modules','phantomjs', 'bin', 'phantomjs')
			else
				cb null, path.join(__dirname, '../../phantomjs')

	_callPhantom: (input, cb) ->
		@_getPhantomFileName (err, phantomJsPath) =>
			childArgs = [
				path.join(__dirname, '../phantomjs/phantom.js')
				JSON.stringify(input)
			]
			output =
				success: ''
				error: ''
			process.env['LD_WARN'] = true
			libraryPath = path.join(__dirname, '../..')
			process.env['LD_LIBRARY_PATH'] = libraryPath
			options =
				maxBuffer: 1024 * 1024
			phantomProcess = childProcess.execFile(phantomJsPath, childArgs, options)
			phantomProcess.stdout.on 'data', (data) ->
				if data?
					# Yay, dirty hack because of https://github.com/ariya/phantomjs/issues/12697
					output.success += data.replace(new RegExp('Unsafe JavaScript attempt to access frame with URL.*','g'), '').trim()

			phantomProcess.stderr.on 'data', (data) ->
				if data?
					output.error += data.replace(new RegExp('Unsafe JavaScript attempt to access frame with URL.*','g'), '').trim()

			phantomProcess.on 'exit', (code) =>
				if !!output.success
					try
						output.success = JSON.parse(output.success)
						output.error = {}
						@_uploadScreenshot input, output, 'success', cb
					catch e
						output.success = "Failed parsing result from PhantomJS"
						output.error = {}
						cb null, output
				else if !!output.error
					try
						output.error = JSON.parse(output.error)
						output.success = {}
						@_uploadScreenshot input, output, 'error', cb
					catch e
						output.error = "Failed parsing result from PhantomJS"
						output.success = {}
						cb null, output
				else
					output.success = {}
					output.error = {}
					cb null, output

	_uploadScreenshot: (input, output, type, cb) ->
		work = []
		work.push (callb) =>
			if input.screenshots? and _.isString(output[type]?.screenshot)
				mimetype = 'image/png'
				if input.screenshots?.args?.format?
					mimetype = "image/#{input.screenshots.args.format}"
				screenshot = output[type].screenshot
				@s3Store.upload input.screenshots.s3.bucket, screenshot, input.screenshots.s3.directory, mimetype, (err, s3Url) ->
					if err?
						output[type].screenshot = "Failed uploading #{screenshot} to S3 bucket #{input.screenshots.s3.bucket}/#{input.screenshots.s3.directory}"
					else
						output[type].screenshot = s3Url
					callb null, output
			else
				callb null, output
		async.waterfall work, (err, result) ->
			cb null, result

module.exports = Girls