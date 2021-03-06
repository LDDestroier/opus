if fs.native then
  return
end

requireInjector(getfenv(1))
local Util = require('util')

fs.native = Util.shallowCopy(fs)

local fstypes = { }
local nativefs = { }

for k,fn in pairs(fs) do
  if type(fn) == 'function' then
    nativefs[k] = function(node, ...)
      return fn(...)
    end
  end
end

function nativefs.list(node, dir, full)

  local files
  if fs.native.isDir(dir) then
    files = fs.native.list(dir)
  end

  local function inList(l, e)
    for _,v in ipairs(l) do
      if v == e then
        return true
      end
    end
  end

  if dir == node.mountPoint and node.nodes then
    files = files or { }
    for k in pairs(node.nodes) do
      if not inList(files, k) then
        table.insert(files, k)
      end
    end
  end

  if not files then
    error('Not a directory')
  end

  return files
end

function nativefs.getSize(node, dir, recursive)
  if recursive and fs.native.isDir(dir) then
    local function sum(dir)
      local total = 0
      local files = fs.native.list(dir)
      for _,f in ipairs(files) do
        local fullName = fs.combine(dir, f)
        if fs.native.isDir(fullName) then
          total = total + sum(fullName)
        else
          total = total + fs.native.getSize(fullName)
        end
      end
      return total
    end
    return sum(dir)
  end
  if node.mountPoint == dir and node.nodes then
    return 0
  end
  return fs.native.getSize(dir)
end

function nativefs.isDir(node, dir)
  if node.mountPoint == dir then
    return not not node.nodes
  end
  return fs.native.isDir(dir)
end

function nativefs.exists(node, dir)
  if node.mountPoint == dir then
    return true
  end
  return fs.native.exists(dir)
end

function nativefs.delete(node, dir)
  if node.mountPoint == dir then
    fs.unmount(dir)
  else
    fs.native.delete(dir)
  end
end

fstypes.nativefs = nativefs
fs.nodes = {
  fs = nativefs,
  mountPoint = '',
  fstype = 'nativefs',
  nodes = { },
}

local function splitpath(path)
  local parts = { }
  for match in string.gmatch(path, "[^/]+") do
    table.insert(parts, match)
  end
  return parts
end

local function getNode(dir)
  local cd = fs.combine(dir, '')
  local parts = splitpath(cd)
  local node = fs.nodes

  for _,d in ipairs(parts) do
    if node.nodes and node.nodes[d] then
      node = node.nodes[d]
    else
      break
    end
  end

  return node
end

local methods = { 'delete', 'getFreeSpace', 'exists', 'isDir', 'getSize',
  'isReadOnly', 'makeDir', 'getDrive', 'list', 'open' }

for _,m in pairs(methods) do
  fs[m] = function(dir, ...)
    dir = fs.combine(dir, '')
    local node = getNode(dir)
    return node.fs[m](node, dir, ...)
  end
end

function fs.complete(partial, dir, includeFiles, includeSlash)
  dir = fs.combine(dir, '')
  local node = getNode(dir)
  if node.fs.complete then
    return node.fs.complete(node, partial, dir, includeFiles, includeSlash)
  end
  return fs.native.complete(partial, dir, includeFiles, includeSlash)
end

function fs.listEx(dir)
  local node = getNode(dir)
  if node.fs.listEx then
    return node.fs.listEx(node, dir)
  end

  local t = { }
  local files = node.fs.list(node, dir)

  pcall(function()
    for _,f in ipairs(files) do
      local fullName = fs.combine(dir, f)
      local file = {
        name = f,
        isDir = fs.isDir(fullName),
        isReadOnly = fs.isReadOnly(fullName),
      }
      if not file.isDir then
        file.size = fs.getSize(fullName)
      end
      table.insert(t, file)
    end
  end)
  return t
end

function fs.copy(s, t)
  local sp = getNode(s)
  local tp = getNode(t)
  if sp == tp and sp.fs.copy then
    return sp.fs.copy(sp, s, t)
  end

  if fs.exists(t) then
    error('File exists')
  end

  if fs.isDir(s) then
    fs.makeDir(t)
    local list = fs.list(s)
    for _,f in ipairs(list) do
      fs.copy(fs.combine(s, f), fs.combine(t, f))
    end

  else
    local sf = Util.readFile(s)
    if not sf then
      error('No such file')
    end

    Util.writeFile(t, sf)
  end
end

function fs.find(spec) -- not optimized
--  local node = getNode(spec)
--  local files = node.fs.find(node, spec)
  local files = { }
  -- method from https://github.com/N70/deltaOS/blob/dev/vfs
  local function recurse_spec(results, path, spec)
    local segment = spec:match('([^/]*)'):gsub('/', '')
    local pattern = '^' .. segment:gsub("[%.%[%]%(%)%%%+%-%?%^%$]","%%%1"):gsub("%z","%%z"):gsub("%*","[^/]-") .. '$'
    if fs.isDir(path) then
      for _, file in ipairs(fs.list(path)) do
        if file:match(pattern) then
          local f = fs.combine(path, file)
          if spec == segment then
            table.insert(results, f)
          end
          if fs.isDir(f) then
            recurse_spec(results, f, spec:sub(#segment + 2))
          end
        end
      end
    end
  end
  recurse_spec(files, '', spec)
  table.sort(files)

  return files
end

function fs.move(s, t)
  local sp = getNode(s)
  local tp = getNode(t)
  if sp == tp and sp.fs.move then
    return sp.fs.move(sp, s, t)
  end
  fs.copy(s, t)
  fs.delete(s)
end

local function getfstype(fstype)
  local vfs = fstypes[fstype]
  if not vfs then
    vfs = require('fs.' .. fstype)
    fs.registerType(fstype, vfs)
  end
  return vfs
end

function fs.mount(path, fstype, ...)

  local vfs = getfstype(fstype)
  if not vfs then
    error('Invalid file system type')
  end
  local node = vfs.mount(path, ...)
  if node then
    local parts = splitpath(path)
    local targetName = table.remove(parts, #parts)

    local tp = fs.nodes
    for _,d in ipairs(parts) do
      if not tp.nodes then
        tp.nodes = { }
      end
      if not tp.nodes[d] then
        tp.nodes[d] = Util.shallowCopy(tp)
        tp.nodes[d].nodes = { }
        tp.nodes[d].mountPoint = fs.combine(tp.mountPoint, d)
      end
      tp = tp.nodes[d]
    end

    node.fs = vfs
    node.fstype = fstype
    if not targetName then
      node.mountPoint = ''
      fs.nodes = node
    else
      node.mountPoint = fs.combine(tp.mountPoint, targetName)
      tp.nodes[targetName] = node
    end
  end
  return node
end

function fs.loadTab(path)
  local mounts = Util.readFile(path)
  if mounts then
    for _,l in ipairs(Util.split(mounts)) do
      if l:sub(1, 1) ~= '#' then
        local s, m = pcall(function()
          fs.mount(table.unpack(Util.matches(l)))
        end)
        if not s then
          printError('Mount failed')
          printError(l)
        end
      end
    end
  end
end

local function getNodeByParts(parts)
  local node = fs.nodes

  for _,d in ipairs(parts) do
    if not node.nodes[d] then
      return
    end
    node = node.nodes[d]
  end
  return node
end

function fs.unmount(path)

  local parts = splitpath(path)
  local targetName = table.remove(parts, #parts)

  local node = getNodeByParts(parts)

  if not node or not node.nodes[targetName] then
    error('Invalid node')
  end

  node.nodes[targetName] = nil
--[[
  -- remove the shadow directories
  while #parts > 0 do
    targetName = table.remove(parts, #parts)
    node = getNodeByParts(parts)
    if not Util.empty(node.nodes[targetName].nodes) then
      break
    end
    node.nodes[targetName] = nil
  end
--]]
end

function fs.registerType(name, fs)
  fstypes[name] = fs
end

function fs.getTypes()
  return fstypes
end

function fs.restore()
  local native = fs.native
  Util.clear(fs)
  Util.merge(fs, native)
end
