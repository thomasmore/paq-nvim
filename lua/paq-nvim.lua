local uv = vim.loop -- Alias for Neovim's event loop (libuv)
local run_hook      -- To handle mutual funtion recursion

local cmd = vim.api.nvim_command       -- nvim 0.4 compat
local vfn = vim.api.nvim_call_function -- ""

-- Constants -------------------------------------------------------------------

local PATH    = vfn('stdpath', {'data'}) .. '/site/pack/paqs/' --TODO: PATH is now configurable, rename!
local LOGFILE = vfn('stdpath', {'cache'}) .. '/paq.log'
local GITHUB  = 'https://github.com/'
local REPO_RE = '^[%w-]+/([%w-_.]+)$'
local DATEFMT = '%F T %H:%M:%S%z'

-- Globals ---------------------------------------------------------------------

local packages = {} -- Table of 'name':{options} pairs
local num_pkgs = 0
local num_to_rm = 0
local ops = {
    clone            = {ok = 0, fail = 0, past = 'cloned'            },
    pull             = {ok = 0, fail = 0, past = 'pulled changes for'},
    remove           = {ok = 0, fail = 0, past = 'removed'           },
}

-- Neovim 0.4 compat -----------------------------------------------------------

local _nvim = {} -- Helper functions to replace 0.5 features

function _nvim.tbl_map(func, t)
    if vfn('has', {'nvim-0.5'}) == 1 then
        return vim.tbl_map(func, t)
    end
    local rettab = {}
    for k, v in pairs(t) do
        rettab[k] = func(v)
    end
    return rettab
end

-- Warning: This mutates dst!
function _nvim.list_extend(dst, src, start, finish)
    if vfn('has', {'nvim-0.5'}) == 1 then
        return vim.list_extend(dst, src, start, finish)
    end
    for i = start or 1, finish or #src do
        table.insert(dst, src[i])
    end
    return dst
end

-- IO --------------------------------------------------------------------------

local function output_result(op, name, ok, ishook)
    local result, msg
    local count = ''
    local failstr = 'Failed to '
    local c = ops[op]

    -- TODO: write a match-like expression. This function got out of control

    if ishook then --hooks aren't counted
        msg = (ok and 'ran ' or failstr .. 'run ') .. string.format('`%s` for', op)
    elseif not c then  --c is not a valid operation
        msg = failstr .. op
    else
        result = ok and 'ok' or 'fail'
        c[result] = c[result] + 1

        local total = (op == 'remove') and num_to_rm or num_pkgs

        count = string.format('%d/%d', c[result], total)
        msg = ok and c.past or failstr .. op

        if c.ok + c.fail == num_pkgs then  --no more packages to update
            c.ok, c.fail = 0, 0
            cmd('packloadall! | helptags ALL')
        end
    end

    print(string.format('Paq [%s] %s %s', count, msg, name))
end

local function call_proc(process, pkg, args, cwd, ishook)
    local log, stderr, handle, op
    log = uv.fs_open(LOGFILE, 'a+', 0x1A4) -- FIXME: Write in terms of uv.constants
    stderr = uv.new_pipe(false)
    stderr:open(log)
    handle = uv.spawn(
        process,
        {args=args, cwd=cwd, stdio = {nil, nil, stderr}},
        vim.schedule_wrap( function(code)
            uv.fs_write(log, '\n', -1) --space out error messages
            uv.fs_close(log)
            stderr:close()
            handle:close()
            output_result(args[1] or process, pkg.name, code == 0, ishook)
            if not ishook then run_hook(pkg) end
        end)
    )
end

function run_hook(pkg) --(already defined as local)
    local t, process, args, ok
    t = type(pkg.run)

    if t == 'function' then
        cmd('packadd ' .. pkg.name)
        local ok = pcall(pkg.run)
        --output_result(t, pkg.name, ok, true)

    elseif t == 'string' then
        args = {}
        for word in pkg.run:gmatch('%S+') do
            table.insert(args, word)
        end
        process = table.remove(args, 1)
        call_proc(process, pkg, args, pkg.dir, true)
    end
end

-- Main Operations ------------------------------------------------------------

local function install(pkg)
    local args = {'clone', pkg.url}
    if pkg.exists then
        ops['clone']['ok'] = ops['clone']['ok'] + 1
        return
    elseif pkg.branch then
        _nvim.list_extend(args, {'-b',  pkg.branch})
    end
    _nvim.list_extend(args, {pkg.dir})
    call_proc('git', pkg, args)
end

local function update(pkg)
    if pkg.exists then
        call_proc('git', pkg, {'pull'}, pkg.dir)
    end
end


local function rmdir(dir)
    local name, t, child, ok
    local handle = uv.fs_scandir(dir)
    while handle do
        name, t = uv.fs_scandir_next(handle)
        if not name then break end

        child = dir .. '/' .. name
        ok = (t == 'directory') and rmdir(child) or uv.fs_unlink(child)

        if not ok then return end
    end
    return uv.fs_rmdir(dir)
end

-- Mark packages for deletion
local function mark_pkgs(dir, opt)
    local pkg, ok
    local list = {}
    local handle = uv.fs_scandir(PATH .. dir)
    while handle do
        name, t = uv.fs_scandir_next(handle)
        if not name then break end
        child = PATH .. dir .. name
        pkg = packages[name]
        if not (pkg and pkg.opt == opt and pkg.dir == child) then
            table.insert(list, {name, child})
        end
    end
    return list
end

local function clean_pkgs()
    local rm_list = {}
    _nvim.list_extend(rm_list, mark_pkgs('start/', false))
    _nvim.list_extend(rm_list, mark_pkgs('opt/', true))
    -- count packages

    num_to_rm = #rm_list
    for _, i in ipairs(rm_list) do
        print(i[1])
        ok = rmdir(i[2])
        output_result('remove', i[1], ok)
    end
end


-- User Config ----------------------------------------------------------------

local function paq(args)
    local name, dir
    if type(args) == 'string' then args = {args} end

    num_pkgs = num_pkgs + 1

    name = args.as or args[1]:match(REPO_RE)
    if not name then return output_result('parse', args[1]) end

    dir = PATH .. (args.opt and 'opt/' or 'start/') .. name

    packages[name] = {
        name   = name,
        branch = args.branch,
        dir    = dir,
        exists = (vfn('isdirectory', {dir}) ~= 0),
        run    = args.run or args.hook, --wait for paq 1.0 to deprecate
        url    = args.url or GITHUB .. args[1] .. '.git',
    }
end

local function setup(args)
    assert(type(args) == 'table')
    if type(args.path) == 'string' then
        PATH = args.path --FIXME: should probably rename PATH
    end
end

-- Exports --------------------------------------------------------------------
return {
    install   = function() _nvim.tbl_map(install, packages) end,
    update    = function() _nvim.tbl_map(update, packages) end,
    clean     = clean_pkgs,
    setup     = setup,
    paq       = paq,
    log_open  = function() cmd('sp ' .. LOGFILE) end,
    log_clean = function() uv.fs_unlink(LOGFILE); print('Paq log file deleted') end,
}
