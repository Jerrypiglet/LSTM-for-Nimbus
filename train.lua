require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'

require 'util.OneHot'
require 'util.misc'
matio = require 'matio'

local DataLoader = require 'util.DataLoader'
local model_utils = require 'util.model_utils'
local LSTM = require 'model.LSTM'
local GRU = require 'model.GRU'
local RNN = require 'model.RNN'

-- there is a better one called llap
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a character-level language model')
cmd:text()
cmd:text('Options')
-- data tinyshakespeare
cmd:option('-data_dir','data/test_','data directory. Should contain the file input.txt with input data')
-- model params
cmd:option('-rnn_size', 32, 'size of LSTM internal state')
cmd:option('-num_layers', 2, 'number of layers in the LSTM')
cmd:option('-model', 'lstm', 'lstm, gru or rnn')
cmd:option('-n_class', 1, 'number of categories')
cmd:option('-nbatches', 1000, 'number of training batches loader prepare')
-- optimization
cmd:option('-learning_rate',1e-2,'learning rate')
cmd:option('-learning_rate_decay',0.1,'learning rate decay')
cmd:option('-learning_rate_decay_every', 5,'in number of epochs, when to start decaying the learning rate')
cmd:option('-decay_rate',0.95,'decay rate for rmsprop')
cmd:option('-dropout',0.5,'dropout for regularization, used after each RNN hidden layer. 0 = no dropout')
cmd:option('-seq_length',1024,'number of timesteps to unroll for') -- 1024, 256
cmd:option('-batch_size',256,'number of sequences to train on in parallel')
cmd:option('-max_epochs', 20,'number of full passes through the training data')
cmd:option('-grad_clip',5,'clip gradients at this value')
cmd:option('-train_frac',0.95,'fraction of data that goes into train set')
cmd:option('-val_frac',0.05,'fraction of data that goes into validation set')
            -- test_frac will be computed as (1 - train_frac - val_frac)
cmd:option('-init_from', '', 'initialize network parameters from checkpoint at this path')
-- bookkeeping
cmd:option('-seed',123,'torch manual random number generator seed')
cmd:option('-print_every',5,'how many steps/minibatches between printing out the loss')
cmd:option('-eval_val_every', 50,'every how many epochs should we evaluate on validation data?')
cmd:option('-checkpoint_dir', 'checkPoints', 'output directory where checkpoints get written')
cmd:option('-savefile','lstmNimbus','filename to autosave the checkpont to. Will be inside checkpoint_dir/')
-- GPU/CPU
cmd:option('-gpuid',1,'which gpu to use. -1 = use CPU')
cmd:option('-opencl',0,'use OpenCL (instead of CUDA)')
cmd:text()

-- parse input params
opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
-- train / val / test split for data, in fractions
local test_frac = math.max(0, 1 - (opt.train_frac + opt.val_frac))
local split_sizes = {opt.train_frac, opt.val_frac, test_frac} 

trainLogger = optim.Logger('train.log')

-- initialize cunn/cutorch for training on the GPU and fall back to CPU gracefully

if opt.gpuid >= 0 and opt.opencl == 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then print('package cunn not found!') end
    if not ok2 then print('package cutorch not found!') end
    if ok and ok2 then
        print('using CUDA on GPU ' .. opt.gpuid .. '...')
        cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        cutorch.manualSeed(opt.seed)
    else
        print('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
        print('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
        print('Falling back on CPU mode')
        opt.gpuid = -1 -- overwrite user setting
    end
end
--]]

-- initialize clnn/cltorch for training on the GPU and fall back to CPU gracefully
if opt.gpuid >= 0 and opt.opencl == 1 then
    local ok, cunn = pcall(require, 'clnn')
    local ok2, cutorch = pcall(require, 'cltorch')
    if not ok then print('package clnn not found!') end
    if not ok2 then print('package cltorch not found!') end
    if ok and ok2 then
        print('using OpenCL on GPU ' .. opt.gpuid .. '...')
        cltorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        torch.manualSeed(opt.seed)
    else
        print('If cltorch and clnn are installed, your OpenCL driver may be improperly configured.')
        print('Check your OpenCL driver installation, check output of clinfo command, and try again.')
        print('Falling back on CPU mode')
        opt.gpuid = -1 -- overwrite user setting
    end
end

-- create the data loader class
local loader = DataLoader.create(opt.data_dir, opt.batch_size, opt.seq_length, split_sizes, opt.n_class, opt.nbatches)
local vocab_size = loader.vocab_size  -- the number of distinct characters
-- local vocab = loader.vocab_mapping
print('vocab size: ' .. vocab_size)
-- make sure output directory exists
if not path.exists(opt.checkpoint_dir) then lfs.mkdir(opt.checkpoint_dir) end

-- define the model: prototypes for one timestep, then clone them in time
local do_random_init = true
if string.len(opt.init_from) > 0 then
    print('loading an LSTM from checkpoint ' .. opt.init_from)
    local checkpoint = torch.load(opt.init_from)
    protos = checkpoint.protos

    -- overwrite model settings based on checkpoint to ensure compatibility
    print('overwriting rnn_size=' .. checkpoint.opt.rnn_size .. ', num_layers=' .. checkpoint.opt.num_layers .. ' based on the checkpoint.')
    opt.rnn_size = checkpoint.opt.rnn_size
    opt.num_layers = checkpoint.opt.num_layers
    do_random_init = false
else
    print('creating an ' .. opt.model .. ' with ' .. opt.num_layers .. ' layers')
    protos = {}
    if opt.model == 'lstm' then
        protos.rnn = LSTM.lstm(vocab_size, opt.n_class, opt.rnn_size, opt.num_layers, opt.dropout, true)
    --[[
    -- discard gru and rnn temporarily
    elseif opt.model == 'gru' then
        protos.rnn = GRU.gru(vocab_size, opt.rnn_size, opt.num_layers, opt.dropout)
    elseif opt.model == 'rnn' then
        protos.rnn = RNN.rnn(vocab_size, opt.rnn_size, opt.num_layers, opt.dropout)
    --]]
    end
    protos.criterion = nn.BCECriterion()
end

-- the initial state of the cell/hidden states
init_state = {}
for L=1,opt.num_layers do
    local h_init = torch.zeros(opt.batch_size, opt.rnn_size)
    if opt.gpuid >=0 and opt.opencl == 0 then h_init = h_init:cuda() end
    if opt.gpuid >=0 and opt.opencl == 1 then h_init = h_init:cl() end
    table.insert(init_state, h_init:clone())
    if opt.model == 'lstm' then
        table.insert(init_state, h_init:clone())
    end
end

-- ship the model to the GPU if desired
if opt.gpuid >= 0 and opt.opencl == 0 then
    for k,v in pairs(protos) do v:cuda() end
end
-- if opt.gpuid >= 0 and opt.opencl == 1 then
--     for k,v in pairs(protos) do v:cl() end
-- end

-- put the above things into one flattened parameters tensor
-- why use model_utils? since it is able to flatten two networks at the same time
params, grad_params = model_utils.combine_all_parameters(protos.rnn)
-- params, grad_params = protos.rnn:getParameters()
--
-- initialization
if do_random_init then
    params:uniform(-0.08, 0.08) -- small uniform numbers  -- just uniform sampling
end
-- initialize the LSTM forget gates with slightly higher biases to encourage remembering in the beginning
if opt.model == 'lstm' then
    for layer_idx = 1, opt.num_layers do
        --print(protos.rnn.forwardnodes)
        for _,node in ipairs(protos.rnn.forwardnodes) do -- where to get forwardnodes? in nngraph
            if node.data.annotations.name == "i2h_" .. layer_idx then
                print('setting forget gate biases to 1 in LSTM layer ' .. layer_idx)
                -- the gates are, in order, i,f,o,g, so f is the 2nd block of weights
                -- which means f is from 128+1 to 256
                node.data.module.bias[{{opt.rnn_size+1, 2*opt.rnn_size}}]:fill(1.0)
            end
        end
    end
end

print('number of parameters in the model: ' .. params:nElement())
-- make a bunch of clones after flattening, as that reallocates memory
-- unroll time steps of rnn and criterion
-- This is for Unrolling
clones = {}
for name,proto in pairs(protos) do
    print('cloning ' .. name)
    clones[name] = model_utils.clone_many_times(proto, opt.seq_length, not proto.parameters)
end


--=============================================
-- evaluate the loss over an entire split
--=============================================
function eval_split(split_index, max_batches)
    print('----- evaluating loss over split index ' .. split_index)
    -- local n = loader.split_sizes[split_index]
    -- local n = math.floor(loader.dataLengthTest / opt.seq_length / opt.batch_size)
    local n = 1
    -- print(loader.dataLengthTest, opt.seq_length, opt.batch_size)
    -- if max_batches ~= nil then n = math.min(max_batches, n) end

    -- loader:reset_batch_pointer(split_index) -- move batch iteration pointer for this split to front
    local loss = 0
    local rnn_state = {[0] = init_state}
    
    if split_index == 2 then
        -- file = torch.DiskFile('valY.txt', 'w')
        predAll = torch.Tensor(opt.seq_length, opt.batch_size, opt.n_class)
        yAll = torch.Tensor(opt.seq_length, opt.batch_size, opt.n_class)
    end

    for i = 1,n do -- iterate over batches in the split; just testing one batch
        -- fetch a batch
        local x, y = loader:next_batch(split_index, i)
        if opt.gpuid >= 0 and opt.opencl == 0 then -- ship the input arrays to GPU
            -- have to convert to float because integers can't be cuda()'d
            x = x:float():cuda()
            y = y:float():cuda()
        end
        if opt.gpuid >= 0 and opt.opencl == 1 then -- ship the input arrays to GPU
            x = x:cl()
            y = y:cl()
        end
        -- forward pass
        for t=1,opt.seq_length do
            clones.rnn[t]:evaluate() -- for dropout proper functioning
            -- local x_OneHot = OneHot(vocab_size):forward(x[{{}, t}]):cuda()
            local x_OneHot = x[t]:cuda()
            local lst = clones.rnn[t]:forward{x_OneHot, unpack(rnn_state[t-1])}
            rnn_state[t] = {}
            for i=1,#init_state do table.insert(rnn_state[t], lst[i]) end
            prediction = lst[#lst]
            loss = loss + clones.criterion[t]:forward(prediction, y[t])

            predAll[t] = prediction:double()
            -- print(prediction)
            yAll[t] = y[t]:float()
            -- if i == 1 and t == 1 then
            --     predAll = prediction:clone()
            --     yAll

            -- if split_index == 2 do
                -- file.writeString()
        end
        -- carry over lstm state
        rnn_state[0] = rnn_state[#rnn_state]

        if split_index == 2 then
            predAll = predAll:transpose(1, 2)
            yAll = yAll:transpose(1, 2)
            predFlat = torch.Tensor(opt.seq_length * opt.batch_size, opt.n_class)
            yFlat = torch.Tensor(opt.seq_length * opt.batch_size, opt.n_class)
            for i = 1, opt.batch_size do
                for j = 1, opt.seq_length do
                    predFlat[(i-1)*opt.seq_length+j] = predAll[i][j]
                    yFlat[(i-1)*opt.seq_length+j] = yAll[i][j]
                end
            end
        end



    end

    loss = loss / opt.seq_length / n
    print('----- loss ' .. loss)

    matio.save(string.format('predAll_%.2f.mat', loss) , {predAll=predFlat})
    matio.save(string.format('yAll_%.2f.mat', loss), {yAll=yFlat})
    -- print(yAll)
    return loss
end


--=============================================
-- [feval]
-- do fwd/bwd and return loss, grad_params
--=============================================

local init_state_global = clone_list(init_state)
-- still don't know how to change grad_params, 
-- How copy_many_times and combine_all_parameters work
-- How can grad_params change when clones change
-- grad_params is being accumulated through time steps, which means the gradient for each time step is accumulated for the whole sequence length
-- And the clones is like a pointer, which just change the original protos.rnn automatically
function feval(x)
        -- print('mark 3-----')
    if x ~= params then
        params:copy(x)
    end
    grad_params:zero()

    ------------------ get minibatch -------------------
    local x, y = loader:next_batch(1) -- 1: training
    if opt.gpuid >= 0 and opt.opencl == 0 then -- ship the input arrays to GPU
        -- have to convert to float because integers can't be cuda()'d
        x = x:float():cuda()
        y = y:float():cuda()
    end
    if opt.gpuid >= 0 and opt.opencl == 1 then -- ship the input arrays to GPU
        x = x:cl()
        y = y:cl()
    end

    -- this is for random dropping a few entries' gradients
    d_rate = 0.5
    -- t = 1
    -- randdroping_mask = y[t]:clone()
    -- chosen_mask = torch.randperm(10)[{{1,math.floor(opt.n_class*d_rate)}}]:cuda()
    -- chosen_mask = chosen_mask:repeatTensor(y[t]:size(1), 1)
    -- randdroping_mask:scatter(2, chosen_mask, 1)

    -- print('mark 4-----')
    ------------------- forward pass -------------------
    local rnn_state = {[0] = init_state_global}
    local predictions = {}           -- softmax outputs
    local loss = 0
    for t=1,opt.seq_length do -- 1 to 50
        clones.rnn[t]:training() -- make sure we are in correct mode (this is cheap, sets flag)
        -- local x_OneHot = OneHot(vocab_size):forward(x[{{}, t}]):cuda()
        local x_OneHot = x[t]:cuda()
        local lst = clones.rnn[t]:forward{x_OneHot, unpack(rnn_state[t-1])}
        rnn_state[t] = {}
        for i=1,#init_state do table.insert(rnn_state[t], lst[i]) end -- extract the state, without output
        predictions[t] = lst[#lst] -- last element is the prediction

        -- loss = loss + clones.criterion[t]:forward(predictions[t]:cmul(randdroping_mask), y[t]) -- to randomly drop with a rate of d_rate
        loss = loss + clones.criterion[t]:forward(predictions[t], y[t]) -- to randomly drop with a rate of d_rate
    end
    -- the loss is the average loss across time steps
    loss = loss / opt.seq_length

        -- print('mark 5-----')
    ------------------ backward pass -------------------
    -- initialize gradient at time t to be zeros (there's no influence from future)
    local drnn_state = {[opt.seq_length] = clone_list(init_state, true)} -- true also zeros the clones, i.e. just clone the size and assign all entries to zeros
    for t=opt.seq_length,1,-1 do
        -- backprop through loss, and softmax/linear
        local doutput_t = clones.criterion[t]:backward(predictions[t], y[t])
        --[[
        if opt.lossfilter == 2 then 
            _, max_ind = torch.abs(y-predictions[t]):max(2)
            max_mat = predictions[t]:clone():fill(0)
            max_mat:scatter(2, max_ind, 1)
            doutput_t = torch.cmul(doutput_t, max_mat)
        end
        --]]
        --print(doutput_t)
        table.insert(drnn_state[t], doutput_t)
        -- still don't know why dlst[1] is empty
        -- print(drnn_state[t])
        -- io.read()
                -- print('mark 6-----')
                local x_OneHot = x[t]:cuda()
        local dlst = clones.rnn[t]:backward({x_OneHot, unpack(rnn_state[t-1])}, drnn_state[t])
                -- print('mark 7-----')
        -- dlst is dlst_dI, need to feed to the previous time step
        drnn_state[t-1] = {}
        for k,v in pairs(dlst) do
            if k > 1 then
                -- note we do k-1 because first item is dembeddings, and then follow the 
                -- derivatives of the state, starting at index 2. I know...
                -- Since the input is x, pre_h, pre_c for two layers
                -- And output is cur_h, cur_c for two layers and output softlog
                drnn_state[t-1][k-1] = v
                -- reverse as the forward one
            end
        end
    end
    -- print 'Out of sequence'

    ------------------------ misc ----------------------
    -- transfer final state to initial state (BPTT)
    init_state_global = rnn_state[#rnn_state] -- NOTE: I don't think this needs to be a clone, right?
    -- grad_params:div(opt.seq_length) -- this line should be here but since we use rmsprop it would have no effect. Removing for efficiency
    -- clip gradient element-wise
    grad_params:clamp(-opt.grad_clip, opt.grad_clip)
    return loss, grad_params
end




--=============================================
-- start optimization here
--=============================================

print("start training:")
train_losses = {}
val_losses = {}
local optim_state = {learningRate = opt.learning_rate, alpha = opt.decay_rate}

--[[]
local optimState = {
    learningRate = opt.learningRate,
    learningRateDecay = 0.0,
                    momentum = opt.momentum,
                         dampening = 0.0,
                              weightDecay = opt.weightDecay
}
]]--

local iterations = opt.max_epochs * loader.ntrain
local iterations_per_epoch = loader.ntrain
local loss0 = nil
local epoch = 1
for i = 1, iterations do
    local new_epoch = math.ceil(i / loader.ntrain)
    local is_new_epoch = false
    if new_epoch > epoch then 
        epoch = new_epoch
        is_new_epoch = true
    end

    local timer = torch.Timer()
    -- print('mark-----')
    local _, loss = optim.rmsprop(feval, params, optim_state)
    -- local _, loss = optim.sgd(feval, params, optim_state)

        -- print('mark 2-----')
    local time = timer:time().real

    local train_loss = loss[1] -- the loss is inside a list, pop it
    train_losses[i] = train_loss

    trainLogger:add{
        ['Loss'] = train_loss
    }
    trainLogger:style{'-'}
    trainLogger.showPlot = false
    trainLogger:plot()
    os.execute('convert -density 200 train.log.eps train.png')

    -- exponential learning rate decay
    if i % loader.ntrain == 0 and opt.learning_rate_decay < 1 then
        if epoch % opt.learning_rate_decay_every == 0 then
            local decay_factor = opt.learning_rate_decay
            optim_state.learningRate = optim_state.learningRate * decay_factor -- decay it
            print('decayed learning rate by a factor ' .. decay_factor .. ' to ' .. optim_state.learningRate)
        end
    end

    -- every now and then or on last iteration
    if i % opt.eval_val_every == 0 or i == iterations then
        -- evaluate loss on validation data
        local val_loss = eval_split(2) -- 2 = validation
        val_losses[i] = val_loss

        local savefile = string.format('%s/lm_%s_%.2f_epoch%d_%.2f.t7', opt.checkpoint_dir, opt.savefile, val_loss, epoch, train_loss)
        print('saving checkpoint to ' .. savefile)
        local checkpoint = {}
        checkpoint.protos = protos
        checkpoint.opt = opt
        checkpoint.train_losses = train_losses
        checkpoint.val_loss = val_loss
        checkpoint.val_losses = val_losses
        checkpoint.i = i
        checkpoint.epoch = epoch
        checkpoint.vocab = loader.vocab_mapping
        checkpoint.loader = loader
        torch.save(savefile, checkpoint)

    end

    if i % opt.print_every == 0 then
        print(string.format("%d/%d (epoch %d), train_loss = %6.8f, grad/param norm = %6.4e, time/batch = %.2fs", i, iterations, epoch, train_loss, grad_params:norm() / params:norm(), time))
    end
   
    if i % 10 == 0 then collectgarbage() end

    -- handle early stopping if things are going really bad
    if loss[1] ~= loss[1] then
        print('loss is NaN.  This usually indicates a bug.  Please check the issues page for existing issues, or create a new issue, if none exist.  Ideally, please state: your operating system, 32-bit/64-bit, your blas version, cpu/cuda/cl?')
        break -- halt
    end
    if loss0 == nil then loss0 = loss[1] end
    if loss[1] > loss0 * 3 then
        print('loss is exploding, aborting.')
        break -- halt
    end
end