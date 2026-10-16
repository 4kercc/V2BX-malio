package node

import (
	"fmt"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	log "github.com/sirupsen/logrus"
)

type Node struct {
	controllers []*Controller
}

func New() *Node {
	return &Node{}
}

func (n *Node) Start(nodes []conf.NodeConfig, core vCore.Core) error {
	n.controllers = make([]*Controller, 0, len(nodes))
	for i := range nodes {
		// A node disabled while preparing the options (node.PrepareOptions) is
		// skipped instead of failing the process: one broken node must not take
		// the machine's other nodes down with it.
		if nodes[i].Disabled {
			log.WithFields(log.Fields{
				"node":   nodes[i].ApiConfig.NodeID,
				"reason": nodes[i].DisabledReason,
			}).Warn("跳过该节点，其它节点照常运行")
			continue
		}
		p, err := panel.New(&nodes[i].ApiConfig)
		if err != nil {
			return err
		}
		// Register controller service
		controller := NewController(core, p, &nodes[i].Options)
		err = controller.Start()
		if err != nil {
			return fmt.Errorf("start node controller [%s-%s-%d] error: %s",
				nodes[i].ApiConfig.APIHost,
				nodes[i].ApiConfig.NodeType,
				nodes[i].ApiConfig.NodeID,
				err)
		}
		n.controllers = append(n.controllers, controller)
	}
	return nil
}

func (n *Node) Close() {
	for _, c := range n.controllers {
		if c == nil {
			continue
		}
		err := c.Close()
		if err != nil {
			panic(err)
		}
	}
	n.controllers = nil
}
