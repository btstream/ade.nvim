-- Data half of Team Changed Files: one worker's net diff against its base.
return function(t)
  local TeamFiles = require("ade.app.team_files")

  local function trimmed(text)
    return (text:gsub("%s+$", ""))
  end

  local function temp_root()
    vim.fn.mkdir("/tmp/opencode", "p")
    local dir = vim.uv.fs_mkdtemp("/tmp/opencode/ade-team-files-data-XXXXXX")
    if not dir then
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
    end
    return dir
  end

  local function git(cwd, args)
    local argv = { "git" }
    vim.list_extend(argv, args)
    local result = vim.system(argv, { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then
      error(table.concat(argv, " ") .. " failed: " .. (result.stderr or ""))
    end
    return trimmed(result.stdout or "")
  end

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local handle = assert(io.open(path, "wb"))
    handle:write(content)
    handle:close()
  end

  ---A repository with one commit and no worktree yet.
  local function repo()
    local root = temp_root()
    local work = root .. "/repo"
    vim.fn.mkdir(work, "p")
    git(work, { "init", "-q" })
    git(work, { "config", "user.email", "test@example.invalid" })
    git(work, { "config", "user.name", "ade test" })
    t.cleanup(function()
      vim.fn.delete(root, "rf")
    end)
    return root, work
  end

  local function commit_base(work, files)
    for name, content in pairs(files) do
      write(work .. "/" .. name, content)
    end
    git(work, { "add", "-A" })
    git(work, { "commit", "-qm", "base" })
    return git(work, { "rev-parse", "HEAD" })
  end

  local function scan(worktree)
    local done, err, files = false
    TeamFiles.scan(worktree, function(scan_err, list)
      err, files, done = scan_err, list, true
    end)
    t.truthy(
      vim.wait(10000, function()
        return done
      end),
      "scan did not call back"
    )
    return err, files
  end

  local function read_base(worktree, path)
    local done, err, content = false
    TeamFiles.read_base(worktree, path, function(read_err, value)
      err, content, done = read_err, value, true
    end)
    t.truthy(
      vim.wait(10000, function()
        return done
      end),
      "read_base did not call back"
    )
    return err, content
  end

  ---@param files table[]
  ---@return table<string, table>
  local function by_path(files)
    local out = {}
    for _, file in ipairs(files) do
      out[file.path] = file
    end
    return out
  end

  t.describe("team changed files data", function()
    t.it("reports committed, staged, unstaged and untracked net changes", function()
      local _, work = repo()
      local base = commit_base(work, {
        ["base.txt"] = "base\n",
        ["keep.txt"] = "keep\n",
        ["gone\nname.txt"] = "deleted content\n",
        ["old\tname.txt"] = "old content\n",
        [".gitignore"] = "*.log\n",
      })
      local worktree = { path = work, branch = "ade/test", base = base }

      -- One committed addition, then staged, unstaged and untracked work.
      write(work .. "/committed.txt", "committed\n")
      git(work, { "add", "committed.txt" })
      git(work, { "commit", "-qm", "worker commit" })
      write(work .. "/staged.txt", "staged\n")
      git(work, { "add", "staged.txt" })
      write(work .. "/base.txt", "changed\n")
      git(work, { "mv", "old\tname.txt", "new\nname.txt" })
      os.remove(work .. "/gone\nname.txt")
      write(work .. "/untracked.txt", "untracked\n")
      write(work .. "/dir/line\nbreak.txt", "nested\n")
      write(work .. "/bad\255name.txt", "bytes\n")
      write(work .. "/ignored.log", "ignored\n")

      local cwd = vim.uv.cwd()
      local err, files = scan(worktree)
      t.falsy(err, tostring(err))
      t.eq(cwd, vim.uv.cwd(), "scan changed the editor's cwd")

      local found = by_path(files)
      t.eq(#files, vim.tbl_count(found), "scan returned a duplicate path")
      t.eq("M", found["base.txt"].status)
      t.eq("A", found["committed.txt"].status)
      t.eq("A", found["staged.txt"].status)
      t.eq("D", found["gone\nname.txt"].status)
      t.eq("R", found["new\nname.txt"].status)
      t.eq("old\tname.txt", found["new\nname.txt"].old_path)
      t.eq("??", found["untracked.txt"].status)
      t.eq("??", found["dir/line\nbreak.txt"].status)
      t.eq("??", found["bad\255name.txt"].status)
      t.falsy(found["ignored.log"], "an ignored file must not be listed")
      t.falsy(found["keep.txt"], "an unchanged file must not be listed")
      for index = 2, #files do
        t.truthy(files[index - 1].path < files[index].path, "files are not sorted by path")
      end
    end)

    t.it("resolves a path recreated after git rm to its current content", function()
      local _, work = repo()
      local base = commit_base(work, {
        ["different.txt"] = "base\n",
        ["same\nname.txt"] = "same\n",
        ["reused.txt"] = "old\n",
        ["gone.txt"] = "gone\n",
        [".gitignore"] = "*.log\n",
      })
      local worktree = { path = work, branch = "ade/test", base = base }

      -- D + ?? at one path: the current file differs from the base.
      git(work, { "rm", "-q", "different.txt" })
      write(work .. "/different.txt", "current\n")
      -- D + ?? at one path: the current file is byte-identical to the base.
      git(work, { "rm", "-q", "same\nname.txt" })
      write(work .. "/same\nname.txt", "same\n")
      -- D + tracked readd: ordinary tracked path reuse.
      git(work, { "rm", "-q", "reused.txt" })
      write(work .. "/reused.txt", "new tracked\n")
      git(work, { "add", "reused.txt" })
      -- An ordinary deletion (nothing at the path) must stay D.
      os.remove(work .. "/gone.txt")
      -- Ignored files stay out of the untracked list even at a removed path.
      write(work .. "/ignored.log", "ignored\n")

      local err, files = scan(worktree)
      t.falsy(err, tostring(err))
      local found = by_path(files)
      t.eq("M", found["different.txt"].status, "a recreated different file must become M")
      t.eq(nil, found["different.txt"].old_path)
      t.falsy(found["same\nname.txt"], "an identical recreated file is not a net change")
      t.eq("M", found["reused.txt"].status, "tracked path reuse is a modification")
      t.eq("D", found["gone.txt"].status, "an ordinary deletion must stay D")
      t.falsy(found["ignored.log"], "an ignored file must not be listed")
      t.eq(#files, vim.tbl_count(found), "scan returned a duplicate path")
    end)

    t.it("stops calling a rename a rename when its source still exists", function()
      local _, work = repo()
      local base = commit_base(work, {
        ["renamed.txt"] = "old content\n",
        ["kept.txt"] = "kept content\n",
      })
      local worktree = { path = work, branch = "ade/test", base = base }

      git(work, { "mv", "renamed.txt", "new-name.txt" })
      write(work .. "/renamed.txt", "recreated\n")
      git(work, { "mv", "kept.txt", "kept-new.txt" })
      write(work .. "/kept.txt", "kept content\n")

      local err, files = scan(worktree)
      t.falsy(err, tostring(err))
      local found = by_path(files)
      t.eq("A", found["new-name.txt"].status, "the destination is an addition")
      t.falsy(found["new-name.txt"].old_path, "a live source makes the old_path misleading")
      t.eq("M", found["renamed.txt"].status, "the recreated source is a modification")
      t.eq("A", found["kept-new.txt"].status)
      t.falsy(found["kept.txt"], "an identical recreated source is not a net change")
      t.eq(#files, vim.tbl_count(found), "scan returned a duplicate path")
    end)

    t.it("keeps two worktrees apart and refuses a parent repository", function()
      local root, work = repo()
      local base = commit_base(work, { ["shared.txt"] = "base\n" })
      local first = root .. "/wt1"
      local second = root .. "/wt2"
      git(work, { "worktree", "add", "-q", "-b", "wt1", first, base })
      git(work, { "worktree", "add", "-q", "-b", "wt2", second, base })
      write(first .. "/shared.txt", "one\n")
      write(first .. "/only1.txt", "one\n")
      write(second .. "/shared.txt", "two\n")
      write(second .. "/only2.txt", "two\n")

      local err1, files1 = scan({ path = first, branch = "wt1", base = base })
      local err2, files2 = scan({ path = second, branch = "wt2", base = base })
      t.falsy(err1, tostring(err1))
      t.falsy(err2, tostring(err2))
      local paths1, paths2 = {}, {}
      for _, file in ipairs(files1) do
        paths1[file.path] = file.status
      end
      for _, file in ipairs(files2) do
        paths2[file.path] = file.status
      end
      t.eq("M", paths1["shared.txt"])
      t.eq("M", paths2["shared.txt"])
      t.eq("??", paths1["only1.txt"])
      t.eq("??", paths2["only2.txt"])
      t.falsy(paths1["only2.txt"], "the first worktree listed the second worktree's file")
      t.falsy(paths2["only1.txt"], "the second worktree listed the first worktree's file")

      -- A subdirectory of the parent repository is not a worker's worktree:
      -- scanning it would quietly report the parent's changes.
      vim.fn.mkdir(work .. "/sub", "p")
      local parent_err = scan({ path = work .. "/sub", branch = "sub", base = base })
      t.truthy(parent_err and parent_err:match("not a git worktree root"), tostring(parent_err))

      -- A removed worktree is an error, not an empty change list.
      git(work, { "worktree", "remove", "--force", first })
      local removed_err = scan({ path = first, branch = "wt1", base = base })
      t.truthy(removed_err and removed_err:match("does not exist"), tostring(removed_err))

      -- A base commit that no longer resolves is an error too.
      local base_err = scan({ path = second, branch = "wt2", base = "deadbeef" })
      t.truthy(base_err, "a missing base commit must fail")
    end)

    t.it("reads a deleted file from the saved base commit", function()
      local root, work = repo()
      local binary = "line one\n\0line two\255\n"
      local base = commit_base(work, {
        ["gone\nname.txt"] = binary,
        ["renamed-old.txt"] = "rename source\n",
      })
      local worktree = { path = work, branch = "ade/test", base = base }
      os.remove(work .. "/gone\nname.txt")
      git(work, { "mv", "renamed-old.txt", "renamed-new.txt" })

      local err, files = scan(worktree)
      t.falsy(err, tostring(err))
      local found = by_path(files)
      t.eq("D", found["gone\nname.txt"].status)
      t.eq("R", found["renamed-new.txt"].status)

      local read_err, content = read_base(worktree, "gone\nname.txt")
      t.falsy(read_err, tostring(read_err))
      t.eq(binary, content, "the base content was not preserved byte for byte")

      -- Leading "./" is still the same worktree-relative path.
      local dotted_err, dotted = read_base(worktree, "./gone\nname.txt")
      t.falsy(dotted_err, tostring(dotted_err))
      t.eq(binary, dotted)

      local old_err, old = read_base(worktree, "renamed-old.txt")
      t.falsy(old_err, tostring(old_err))
      t.eq("rename source\n", old)

      local missing_err = read_base(worktree, "missing.txt")
      t.truthy(missing_err, "a path absent from the base must fail")

      local absolute_err = read_base(worktree, work .. "/gone\nname.txt")
      t.truthy(absolute_err and absolute_err:match("relative"), tostring(absolute_err))
      local parent_err = read_base(worktree, "../outside.txt")
      t.truthy(parent_err and parent_err:match("inside the worktree"), tostring(parent_err))

      vim.fn.delete(root .. "/repo", "rf")
      local removed_err = read_base(worktree, "gone\nname.txt")
      t.truthy(removed_err and removed_err:match("does not exist"), tostring(removed_err))
    end)
  end)
end
