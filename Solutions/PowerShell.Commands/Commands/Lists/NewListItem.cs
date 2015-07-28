using Microsoft.SharePoint.Client;
using OfficeDevPnP.PowerShell.CmdletHelpAttributes;
using OfficeDevPnP.PowerShell.Commands.Base.PipeBinds;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Text;
using System.Threading.Tasks;

namespace OfficeDevPnP.PowerShell.Commands.Lists
{
    [Cmdlet(VerbsCommon.New, "SPOListItem")]
    [CmdletHelp("Creates list items", Category = "Lists")]
    [CmdletExample(Code = "PS:> New-SPOListItem -List Tasks -Values @{ 'Title'='A new task.'; 'Description'='This is a new task.' }", Remarks = "Creates a new list item in the Tasks list", SortOrder = 1)]
    [CmdletExample(Code = "PS:> New-SPOListItem -List Tasks -Values @{ 'Title'='A new task.'; 'Description'='This is a new task.' } -Folder 'Support Tasks/Data Issues'", Remarks = "Creates a new item in the 'Support Tasks' folder.", SortOrder = 2)]
    public class NewListItem : SPOWebCmdlet
    {
        [Parameter(Mandatory = true, HelpMessage = "The list to query", Position = 0)]
        public ListPipeBind List;

        [Parameter(Mandatory = true, HelpMessage = "The data to set on the new list item.", Position=1)]
        public Hashtable Values;

        [Parameter(Mandatory = false, HelpMessage = "The folder to create the item in.")]
        public string Folder = "/";

        protected override void ExecuteCmdlet() {
            var list = SelectedWeb.GetList(this.List);
            var itemParams = new ListItemCreationInformation() {
                    FolderUrl = this.Folder, 
                    UnderlyingObjectType = FileSystemObjectType.File
                    };
            var item = list.AddItem(itemParams);
            foreach (var k in this.Values.Keys) {
                item[k.ToString()] = this.Values[k];
            }
            item.Update();
            this.ClientContext.ExecuteQueryRetry();
        }
    }
}
