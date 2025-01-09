#!/bin/bash

# Variables for the installation
WEB_ROOT="/var/www/html/cwp-to-cpanel"
DEFAULT_WEB_SERVER="apache"  # Default web server (apache)

# Function to prompt the user to choose web server
choose_web_server() {
    echo "Please choose the web server you want to use:"
    echo "1) Apache"
    echo "2) Nginx"
    read -p "Enter your choice (1-2): " WEB_SERVER_CHOICE

    case $WEB_SERVER_CHOICE in
        1) WEB_SERVER="apache" ;;
        2) WEB_SERVER="nginx" ;;
        *) WEB_SERVER="apache" ;;  # Default to Apache if no valid input
    esac

    echo "You have chosen the web server: $WEB_SERVER"
}

# Function to set up the web interface (HTML & PHP)
setup_web_interface() {
    echo "Setting up migration web interface..."

    # Create directory for web files
    mkdir -p $WEB_ROOT

    # Download or copy the migration files (HTML & PHP scripts)
    cat > $WEB_ROOT/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CWP Pro to cPanel Migration</title>
    <style>
        /* Styles from previous HTML */
    </style>
</head>
<body>
    <h2>CWP Pro to cPanel Migration</h2>
    <form id="migrationForm">
        <label for="cwp_host">CWP Pro Host:</label>
        <input type="text" id="cwp_host" name="cwp_host" placeholder="CWP Pro Server IP or Domain" required>

        <label for="cwp_user">CWP Pro Username:</label>
        <input type="text" id="cwp_user" name="cwp_user" placeholder="CWP Pro Username" required>

        <label for="cwp_pass">CWP Pro Password:</label>
        <input type="password" id="cwp_pass" name="cwp_pass" placeholder="CWP Pro Password" required>

        <label for="cpanel_host">cPanel Host:</label>
        <input type="text" id="cpanel_host" name="cpanel_host" placeholder="cPanel Server IP or Domain" required>

        <label for="cpanel_user">cPanel Username:</label>
        <input type="text" id="cpanel_user" name="cpanel_user" placeholder="cPanel Username" required>

        <label for="cpanel_pass">cPanel Password:</label>
        <input type="password" id="cpanel_pass" name="cpanel_pass" placeholder="cPanel Password" required>

        <button type="submit">Start Migration</button>
    </form>

    <div id="statusMessage" class="status"></div>

    <script>
        // JavaScript from previous HTML
    </script>

</body>
</html>
EOF

    cat > $WEB_ROOT/migrate.php << 'EOF'
<?php
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    // Get POST data
    $cwp_host = $_POST['cwp_host'];
    $cwp_user = $_POST['cwp_user'];
    $cwp_pass = $_POST['cwp_pass'];
    $cpanel_host = $_POST['cpanel_host'];
    $cpanel_user = $_POST['cpanel_user'];
    $cpanel_pass = $_POST['cpanel_pass'];

    // Example of running the migration (file transfer, database, etc.)
    try {
        // Perform migration logic here (rsync, mysqldump, etc.)

        // Sample file transfer using rsync
        $ssh_command = "rsync -avz --progress $cwp_user@$cwp_host:/home/$cwp_user/public_html/ /home/$cpanel_user/public_html/";
        exec($ssh_command, $output, $status);

        if ($status === 0) {
            echo json_encode(['success' => true]);
        } else {
            throw new Exception('File transfer failed.');
        }

    } catch (Exception $e) {
        echo json_encode(['success' => false, 'error' => $e->getMessage()]);
    }
}
?>
EOF

    # Set permissions for the web files
    chown -R apache:apache $WEB_ROOT
    chmod -R 755 $WEB_ROOT
}

# Function to configure Apache web server
configure_apache() {
    echo "Configuring Apache..."

    # Enable and start Apache service
    systemctl enable httpd
    systemctl start httpd

    # Open necessary ports (HTTP 80)
    firewall-cmd --zone=public --add-port=80/tcp --permanent
    firewall-cmd --reload
}

# Function to configure Nginx web server
configure_nginx() {
    echo "Configuring Nginx..."

    # Enable and start Nginx service
    systemctl enable nginx
    systemctl start nginx

    # Open necessary ports (HTTP 80)
    firewall-cmd --zone=public --add-port=80/tcp --permanent
    firewall-cmd --reload
}

# Function to set up SSH for file transfer (Optional)
setup_ssh() {
    echo "Setting up SSH access..."

    # Install SSH client and utilities (if not already installed)
    yum install -y openssh-clients

    # Set up SSH keys for passwordless login (optional)
    ssh-keygen -t rsa
    ssh-copy-id cwp_user@$cwp_host
    ssh-copy-id cpanel_user@$cpanel_host
}

# Main installation function
install() {
    # Choose web server
    choose_web_server

    # Set up web interface
    setup_web_interface

    # Configure the selected web server
    if [ "$WEB_SERVER" == "apache" ]; then
        configure_apache
    elif [ "$WEB_SERVER" == "nginx" ]; then
        configure_nginx
    fi

    # Set up SSH (optional)
    setup_ssh

    echo "Installation completed successfully!"
}

# Run the installation
install
