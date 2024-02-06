package main

import (
	"os"

	"gopkg.in/yaml.v2"
)

type (
	vpn struct {
		Port      int
		OpenVPN   string
		Sudo      string
		Shell     string
		ShellArgs []string
	}

	server struct {
		Addr string
	}

	browser struct {
		Command     string
		CommandArgs []string
	}

	config struct {
		Vpn     vpn
		Server  server
		Browser browser
	}
)

func loadConfig(filename string) (c *config, err error) {
	fileBytes, err := os.ReadFile(filename)

	if err != nil {
		return
	}

	c = &config{}
	err = yaml.Unmarshal(fileBytes, c)

	return
}
